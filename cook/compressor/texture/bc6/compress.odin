package bc6

import "base:intrinsics"
import "core:simd"
import "mirai:asset"
import "mirai:cook/compressor/texture/bc67"
import "mirai:cook/compressor/texture/common"

// Unsigned BC6H (BC6U) encoder. Endpoints live in the space of the half
// float bit patterns, where the interpolation of the format takes place; the
// error is MRSSE, a squared difference divided by twice the squared magnitude
// of the source texel, measured in floats.

Flag :: enum u8 {
    Lsq_Fit,
    Pca_Stretch,
    Jitter_Selectors,
    Anneal_Endpoints,
    Pca,
    Slide_Selectors,
    Extrapolate_Selectors,
    Aggressive_Mode_Prune = 8,
    Weighted_Channels,
}
Flags :: bit_set[Flag;u32]

Enc_Options :: struct {
    max_part:int, // partitions searched in the seed phase
    narrow0,narrow1,narrow2:int, // candidates kept after seeding, fitting and least squares
    max_lsq_iter:int,
    max_pca_stretch_passes:int,
    optiters_early:[2]int, // jitter and anneal iterations on each narrow2 candidate
    optiters_late:[2]int,  // the same on the best candidate
    flags:Flags,
}

Error :: u32
ERROR_MAX :: ~u32(0)

@(private)
Mode_Desc :: struct {
    epb:int,    // endpoint bits
    db:[3]int,  // delta bits per channel
    is_two_subset:bool,
}

// The 14 modes, then the proxies of one subset (14) and two subsets (15)
// that seeds use before a real mode is chosen.
@(rodata,private)
MODE_DESC := [16]Mode_Desc{
    {10,{5,5,5},true},{7,{6,6,6},true},{11,{5,4,4},true},{11,{4,5,4},true},
    {11,{4,4,5},true},{9,{5,5,5},true},{8,{6,5,5},true},{8,{5,6,5},true},
    {8,{5,5,6},true},{6,{0,0,0},true},{10,{0,0,0},false},{11,{9,9,9},false},
    {12,{8,8,8},false},{16,{4,4,4},false},
    {12,{0,0,0},false},{11,{0,0,0},true},
}

// Two-subset partitions by how often they win, grouped by shape.
@(rodata,private)
PARTITION_ORDER := [32]int{
    0,13,1,2,14,15,3,10,16,23,6,7,19,21,26,29,5,11,12,17,18,25,4,8,9,20,22,24,27,28,30,31,
}

// sqrt of the per-channel weights: none, or luma (CIE Y, square-rooted and normalized).
@(rodata,private)
WEIGHTS_SQRT := [2][3]f32{{1,1,1},{0.54331,0.79528,0.26897}}

Rand_State :: struct {x,y,z,c:u32}

RAND_INIT :: Rand_State{123456789,362436000,521288629,7654321}

// KISS99.
rand32 :: proc "contextless" (r:^Rand_State) -> u32 {
    r.x=69069*r.x+12345
    r.y~=r.y<<13
    r.y~=r.y>>17
    r.y~=r.y<<5
    t:=u64(698769069)*u64(r.z)
    t+=u64(r.c)
    r.c=u32(t>>32)
    r.z=u32(t)
    ret:=r.x+r.y+r.z
    ret+=ret>>15
    return ret
}

rand_mod :: #force_inline proc "contextless" (r:^Rand_State,count:u32) -> u32 {
    return u32((u64(rand32(r))*u64(count))>>32)
}

Input :: struct {
    blocki:[3][16]i32,       // [channel][texel] half bit patterns
    blockf32:[3][16]f32,     // [channel][texel] values times the channel weight
    weightf32:[16]f32,       // 1/(2*|texel|^2) of MRSSE
    blockf_lsq:[64]f32,      // the half bit patterns as floats, and the texel weight in 3
    rand_seed:Rand_State,
    channel_weights_sqrt:[3]f32,
}

@(private)
Partition_Prep :: struct {
    mean:[2][3]f32,
    pca:[2][3]f32,
}

Endpoints :: struct {
    raw:[4][3]i16,   // [subset*2+lohi][channel] half bit patterns
    quant:[4][3]i32, // [subset*2+lohi][channel]
}

@(private)
Prep_Info :: struct {
    prep:Partition_Prep,
    initial_ep:Endpoints,
}

@(private)
Prep :: struct {
    sub1:Prep_Info,
    sub2:[32]Prep_Info,
}

Block_State :: struct {
    idxs:[16]u8,
    err:Error,
    endpoints:Endpoints,
    mode,p:u8,
}

@(private)
Color_Set :: struct {
    col:[2][3][16]f32, // [subset][channel][index] interpolated values times the channel weight
}

// (int)f of x64 (cvttss2si): out of range and NaN give INT_MIN.
@(private)
ftoi :: #force_inline proc "contextless" (f:f32) -> i32 {
    if f>=-2147483648.0 && f<2147483648.0 {return i32(f)}
    return min(i32)
}

// A finite half to float (exact, subnormals included).
half_to_f32 :: #force_inline proc "contextless" (h:u16) -> f32 {
    f:=transmute(f32)(u32(h&0x7fff)<<13)*transmute(f32)u32((254-15)<<23)
    return transmute(f32)(transmute(u32)f|u32(h&0x8000)<<16)
}

@(private)
quant :: #force_inline proc "contextless" (epb,ep:int) -> i32 {
    if epb!=16 {return i32((ep<<uint(epb))/0x7c00)}
    return i32((ep*64+30)/31)
}

@(private)
dequant :: #force_inline proc "contextless" (epb:int,v:i32) -> int {
    if epb<16 {
        mask:=(1<<uint(epb))-1
        x:=int(v)&mask
        if x==0 {return 0}
        if x==mask {return 0xffff}
        return ((x<<16)+0x8000)>>uint(epb)
    }
    return int(v)&0xffff
}

@(private)
scaled_to_half :: #force_inline proc "contextless" (x:int) -> int {
    return (x*31)>>6
}

@(private)
round_endpoint :: #force_inline proc "contextless" (v:f32,min_v:int) -> i16 {
    r:=int(ftoi(v+(v>=0 ? 0.5 : -0.5)))
    return i16(clamp(r,min_v,0x7bff))
}

input_init :: proc "contextless" (input:^Input,blk:^[16][4]u16,seed:Rand_State,flags:Flags) {
    input.channel_weights_sqrt=WEIGHTS_SQRT[.Weighted_Channels in flags ? 1 : 0]
    w:=input.channel_weights_sqrt
    for i in 0..<16 {
        for c in 0..<3 {
            h:=blk[i][c]
            input.blocki[c][i]=i32(i16(h<0x8000 ? int(h) : 0x8000-int(h)))
            input.blockf_lsq[i*4+c]=f32(input.blocki[c][i])
            input.blockf32[c][i]=half_to_f32(h)*w[c]
        }
        input.blockf_lsq[i*4+3]=1
        b:=&input.blockf32
        sum_sq:=b[0][i]*b[0][i]+b[1][i]*b[1][i]+b[2][i]*b[2][i]
        // The smallest half subnormal, squared.
        sum_sq=sum_sq>1.42108547e-14 ? sum_sq : 1.42108547e-14
        input.weightf32[i]=0.5/sum_sq
    }
    input.rand_seed=seed
}

@(private)
calc_subset_pca :: proc "contextless" (pp:^Partition_Prep,s:int,cov:^[6]f32,ep:[]([3]i16)) {
    local:[3]f32
    len_sq:f32
    for i in 0..<3 {
        local[i]=f32(int(ep[1][i])-int(ep[0][i]))
        len_sq+=local[i]*local[i]
    }
    if len_sq<=2.0*2.0 {
        pp.pca[s]={}
        return
    }
    for _ in 0..<3 {
        x:=cov[0]*local[0]+cov[3]*local[1]+cov[5]*local[2]
        y:=cov[3]*local[0]+cov[1]*local[1]+cov[4]*local[2]
        z:=cov[5]*local[0]+cov[4]*local[1]+cov[2]*local[2]
        len_sq=x*x+y*y+z*z
        if !(len_sq>0) {break}
        norm:=1/intrinsics.sqrt(len_sq)
        local={x*norm,y*norm,z*norm}
    }
    pp.pca[s]=local
}

@(private)
prep_calc :: proc "contextless" (pp:^Partition_Prep,input:^Input,p,ns:int,out:^[4][3]i16) {
    inds:=bc67.SUBSET_TO_INDS[ns-1][p]
    for s in 0..<ns {
        num:=int(bc67.NUM_PIXELS_PER_SUBSET[ns][p][s])
        minf:=[3]f32{65504,65504,65504}
        maxf:=[3]f32{-65504,-65504,-65504}
        sumf:[3]f32
        cov:[6]f32
        for _ in 0..<num {
            i:=int(inds&0xf)
            inds>>=4
            r:=input.blockf_lsq[i*4+0]
            g:=input.blockf_lsq[i*4+1]
            b:=input.blockf_lsq[i*4+2]
            px:=[3]f32{r,g,b}
            for c in 0..<3 {
                minf[c]=minf[c]<px[c] ? minf[c] : px[c]
                maxf[c]=maxf[c]>px[c] ? maxf[c] : px[c]
                sumf[c]+=px[c]
            }
            cov[0]+=r*r
            cov[1]+=g*g
            cov[2]+=b*b
            cov[3]+=r*g
            cov[4]+=g*b
            cov[5]+=b*r
        }
        sf:=1/f32(num)
        sumf*=sf
        cov[0]=cov[0]*sf-sumf[0]*sumf[0]
        cov[1]=cov[1]*sf-sumf[1]*sumf[1]
        cov[2]=cov[2]*sf-sumf[2]*sumf[2]
        cov[3]=cov[3]*sf-sumf[0]*sumf[1]
        cov[4]=cov[4]*sf-sumf[1]*sumf[2]
        cov[5]=cov[5]*sf-sumf[2]*sumf[0]
        for c in 0..<3 {
            pp.mean[s][c]=sumf[c]
            out[s*2+0][c]=round_endpoint(minf[c],0)
            out[s*2+1][c]=round_endpoint(maxf[c],0)
        }
        calc_subset_pca(pp,s,&cov,out[s*2:s*2+2])
    }
}

@(private)
prep_init :: proc "contextless" (prep:^Prep,input:^Input,opt:^Enc_Options) {
    prep^={}
    prep_calc(&prep.sub1.prep,input,0,1,&prep.sub1.initial_ep.raw)
    for i in 0..<min(opt.max_part,32) {
        p:=PARTITION_ORDER[i]
        prep_calc(&prep.sub2[p].prep,input,p,2,&prep.sub2[p].initial_ep.raw)
    }
}

@(private)
quantize_endpoints :: #force_inline proc "contextless" (ep:^Endpoints,desc:^Mode_Desc,$ns:int) {
    for i in 0..<ns*2 {
        for c in 0..<3 {ep.quant[i][c]=quant(desc.epb,int(ep.raw[i][c]))}
    }
}

// Prunes the modes to try, so it errs on the side of letting a mode through.
@(private)
can_fit_mode :: proc "contextless" (ep:^Endpoints,index:int,$ns:int) -> bool {
    MAX_DELTA :: 0x7c00
    TOO_LARGE_DELTA :: MAX_DELTA+(MAX_DELTA>>2)
    desc:=&MODE_DESC[index]
    if desc.db[0]==0 {return true}
    for c in 0..<3 {
        bit_loss:=desc.epb-(desc.db[c]-1)
        too_large:=TOO_LARGE_DELTA>>uint(bit_loss)
        for i in 1..<2*ns {
            if abs(int(ep.raw[i][c])-int(ep.raw[0][c]))>=too_large {return false}
        }
    }
    return true
}

@(private)
Result :: struct {
    err:Error,
    slot:int,
}

@(private)
MAX_RESULTS :: 64

// A max-heap by error of the best states seen, at most num of them.
@(private)
Results :: struct {
    best_err:Error,
    num,used:int,
    heap:[MAX_RESULTS]Result,
    pool:[MAX_RESULTS]Block_State,
}

@(private)
results_init :: proc "contextless" (r:^Results,num:int) {
    r.best_err=ERROR_MAX
    r.num=clamp(num,1,MAX_RESULTS)
    r.used=0
    for i in 0..<MAX_RESULTS {
        r.heap[i]={ERROR_MAX,i}
        r.pool[i]={err=ERROR_MAX}
    }
}

@(private)
adjust_heap :: proc "contextless" (heap:[]Result,start,n:int) {
    i:=start
    for {
        child:=i*2+1
        if child>=n {break}
        if child+1<n && heap[child].err<heap[child+1].err {child+=1}
        if heap[child].err<heap[i].err {break}
        heap[i],heap[child]=heap[child],heap[i]
        i=child
    }
}

@(private)
make_heap :: proc "contextless" (heap:[]Result) {
    n:=len(heap)
    for cur:=n>>1;cur>0; {
        cur-=1
        adjust_heap(heap,cur,n)
    }
}

@(private)
results_add :: proc "contextless" (r:^Results,st:^Block_State) {
    if st.err<r.best_err {r.best_err=st.err}
    if r.used<r.num {
        r.heap[r.used].err=st.err
        r.pool[r.heap[r.used].slot]=st^
        r.used+=1
        if r.used==r.num {make_heap(r.heap[:r.used])}
        return
    }
    if st.err>=r.heap[0].err {return}
    r.heap[0].err=st.err
    r.pool[r.heap[0].slot]=st^
    adjust_heap(r.heap[:],0,r.used)
}

// Runs after refinements, so the errors of the heap are refreshed first.
@(private)
results_shrink :: proc "contextless" (r:^Results,new_num:int) {
    if r.used<=new_num {
        r.num=new_num
        return
    }
    for i in 0..<r.used {r.heap[i].err=r.pool[r.heap[i].slot].err}
    make_heap(r.heap[:new_num])
    for i in new_num..<r.used {
        if r.heap[i].err>=r.heap[0].err {continue}
        r.heap[0],r.heap[i]=r.heap[i],r.heap[0]
        adjust_heap(r.heap[:],0,new_num)
    }
    r.num=new_num
    r.used=new_num
}

@(private)
color_set_init :: proc "contextless" (set:^Color_Set,ep:^Endpoints,mode:^Mode_Desc,weights:[3]f32,
    $ns:int) #no_bounds_check {
    IB :: uint(5-ns)
    N :: 1<<IB
    V :: #simd[16]i32
    VU :: #simd[16]u32
    VF :: #simd[16]f32
    lerp:=cast(V)transmute(#simd[16]u8)asset.BC7_WEIGHTS[IB]
    for s in 0..<ns {
        for c in 0..<3 {
            ep0:=dequant(mode.epb,ep.quant[s*2+0][c])
            ep1:=dequant(mode.epb,ep.quant[s*2+1][c])
            a:=simd.shr(V(i32(ep0*64+32))+lerp*V(i32(ep1-ep0)),VU(6))
            a=simd.shr(a*V(31),VU(6))
            // A positive finite half to float.
            f:=transmute(VF)simd.shl(transmute(VU)a&VU(0x7fff),VU(13))*VF(transmute(f32)u32((254-15)<<23))
            v:=transmute([16]f32)(f*VF(weights[c]))
            for i in 0..<N {set.col[s][c][i]=v[i]}
        }
    }
}

// The best index of every texel: the errors of four entries at a time, the index in the low
// mantissa bits so the minimum carries it.
@(private)
calc_indexes :: proc "contextless" (input:^Input,st:^Block_State,set:^Color_Set,
    $ns:int) -> Error #no_bounds_check {
    NUM_LERP :: 1<<uint(5-ns)
    V4 :: #simd[4]f32
    U4 :: #simd[4]u32
    im:=bc67.SECTION_TBL[ns][st.p]
    best_arr:[16]V4
    for i in 0..<16 {
        s:=im&1
        im>>=2
        col:=&set.col[s]
        pr,pg,pb:=V4(input.blockf32[0][i]),V4(input.blockf32[1][i]),V4(input.blockf32[2][i])
        best:=transmute(V4)U4(255<<23)
        for j:=0; j<NUM_LERP; j+=4 {
            dr:=intrinsics.unaligned_load((^V4)(&col[0][j]))-pr
            dg:=intrinsics.unaligned_load((^V4)(&col[1][j]))-pg
            db:=intrinsics.unaligned_load((^V4)(&col[2][j]))-pb
            e:=transmute(U4)(dr*dr+dg*dg+db*db)
            e=(e&U4(~u32(15)))|(U4{0,1,2,3}+U4(u32(j)))
            best=simd.min(best,transmute(V4)e)
        }
        best_arr[i]=best
    }
    sums:V4
    for i:=0; i<16; i+=4 {
        a,b,c,d:=best_arr[i],best_arr[i+1],best_arr[i+2],best_arr[i+3]
        // Transposed, so each lane holds the four candidates of one texel.
        t0:=simd.shuffle(a,b,0,4,1,5); t1:=simd.shuffle(a,b,2,6,3,7)
        t2:=simd.shuffle(c,d,0,4,1,5); t3:=simd.shuffle(c,d,2,6,3,7)
        r0:=simd.shuffle(t0,t2,0,1,4,5); r1:=simd.shuffle(t0,t2,2,3,6,7)
        r2:=simd.shuffle(t1,t3,0,1,4,5); r3:=simd.shuffle(t1,t3,2,3,6,7)
        best:=simd.min(simd.min(r0,r1),simd.min(r2,r3))
        idx:=transmute([4]u32)(transmute(U4)best&U4(15))
        for k in 0..<4 {st.idxs[i+k]=u8(idx[k])}
        sums+=best*intrinsics.unaligned_load((^V4)(&input.weightf32[i]))
    }
    sa:=transmute([4]f32)sums
    total:=(sa[0]+sa[2])+(sa[1]+sa[3])
    return Error(ftoi(total*65536))
}

@(private)
eval_indexes :: proc "contextless" (input:^Input,st:^Block_State,set:^Color_Set,$ns:int) -> Error {
    im:=bc67.SECTION_TBL[ns][st.p]
    total:f32
    for i in 0..<16 {
        s:=im&3
        im>>=2
        ind:=st.idxs[i]&15
        dr:=input.blockf32[0][i]-set.col[s&1][0][ind]
        dg:=input.blockf32[1][i]-set.col[s&1][1][ind]
        db:=input.blockf32[2][i]-set.col[s&1][2][ind]
        e:=dr*dr+dg*dg+db*db
        total+=e*input.weightf32[i]
    }
    return Error(ftoi(total*65536))
}

// Quantizes the endpoints and clamps the deltas to their range; whether any
// was clamped.
@(private)
calc_endpoints :: proc "contextless" (ep:^Endpoints,desc:^Mode_Desc,$ns:int) -> bool {
    any_clamps:=false
    quantize_endpoints(ep,desc,ns)
    if desc.db[0]!=0 {
        for c in 0..<3 {
            base:=ep.quant[0][c]
            sign_bit:=i32(1)<<uint(desc.db[c]-1)
            for i in 1..<ns*2 {
                clamped:=clamp(ep.quant[i][c],base-sign_bit,base+sign_bit-1)
                if clamped!=ep.quant[i][c] {
                    any_clamps=true
                    ep.quant[i][c]=clamped
                }
            }
        }
    }
    return any_clamps
}

@(private)
trivial_flip_possible :: proc "contextless" (ep:^Endpoints,mode:^Mode_Desc,$ns:int) -> bool {
    for c in 0..<3 {
        base:=ep.quant[1][c]
        sign_bit:=i32(1)<<uint(mode.db[c]-1)
        for j in 1..<ns*2 {
            i:=j~1
            if ep.quant[i][c]<base-sign_bit || ep.quant[i][c]>=base+sign_bit {return false}
        }
    }
    return true
}

@(private)
flip_subset_inds :: proc "contextless" (inds:^[16]u8,subset_mask:u32,which:u32,flip_bits:u8) {
    m:=subset_mask
    for i in 0..<16 {
        if m&3==which {inds[i]~=flip_bits}
        m>>=2
    }
}

@(private)
swap_endpoints :: proc "contextless" (ep:^Endpoints,a,b:int) {
    for c in 0..<3 {
        ep.raw[a][c],ep.raw[b][c]=ep.raw[b][c],ep.raw[a][c]
        ep.quant[a][c],ep.quant[b][c]=ep.quant[b][c],ep.quant[a][c]
    }
}

// Clears the anchor bit of texel 0. Swapping the endpoints moves the base of
// the deltas, which may then be out of range, so with large deltas the
// cheaper patch of index 0 is weighed against a real swap.
@(private)
fix_delta_endpoint01 :: proc "contextless" (input:^Input,st:^Block_State,set:^Color_Set,
    mode:^Mode_Desc,any_clamps:bool,$ns:int) {
    IB :: uint(5-ns)
    ANCHOR_BIT :: u8(1<<(IB-1))
    if mode.db[0]==0 || st.idxs[0]&ANCHOR_BIT==0 {return}
    if !any_clamps && trivial_flip_possible(&st.endpoints,mode,ns) {
        flip_subset_inds(&st.idxs,bc67.SECTION_TBL[ns][st.p],0,(1<<IB)-1)
        swap_endpoints(&st.endpoints,0,1)
        return
    }
    st.idxs[0]=ANCHOR_BIT-1
    st.err=eval_indexes(input,st,set,ns)

    nst:=st^
    for c in 0..<3 {
        r:=&nst.endpoints.raw
        r[0][c],r[1][c]=r[1][c],r[0][c]
    }
    calc_endpoints(&nst.endpoints,mode,ns)
    color_set_init(set,&nst.endpoints,mode,input.channel_weights_sqrt,ns)
    nst.err=calc_indexes(input,&nst,set,ns)
    // Deltas are two's complement: the swap need not be an exact mirror, and
    // the anchor bit can come back.
    if nst.idxs[0]&ANCHOR_BIT!=0 {
        nst.idxs[0]=ANCHOR_BIT-1
        nst.err=eval_indexes(input,&nst,set,ns)
    }
    if nst.err<st.err {st^=nst}
}

// Index search with both anchor bits forced clear.
@(private)
calc_indexes_anchor_zero :: proc "contextless" (input:^Input,st:^Block_State,set:^Color_Set,
    $ns:int) -> Error {
    IB :: uint(5-ns)
    ANCHOR_BIT :: u8(1<<(IB-1))
    err:=calc_indexes(input,st,set,ns)
    anchor2:=ns==1 ? 0 : int(asset.BC7_ANCHORS_2[st.p])
    if (st.idxs[0]|st.idxs[anchor2])&ANCHOR_BIT!=0 {
        if st.idxs[0]&ANCHOR_BIT!=0 {st.idxs[0]=ANCHOR_BIT-1}
        if st.idxs[anchor2]&ANCHOR_BIT!=0 {st.idxs[anchor2]=ANCHOR_BIT-1}
        err=eval_indexes(input,st,set,ns)
    }
    return err
}

@(private)
trial :: proc "contextless" (input:^Input,st:^Block_State,mode:^Mode_Desc,$ns:int) {
    any_clamps:=calc_endpoints(&st.endpoints,mode,ns)
    set:Color_Set
    color_set_init(&set,&st.endpoints,mode,input.channel_weights_sqrt,ns)
    st.err=calc_indexes(input,st,&set,ns)
    fix_delta_endpoint01(input,st,&set,mode,any_clamps,ns)
}

@(private)
try_and_commit :: proc "contextless" (input:^Input,cur_best,st:^Block_State,mode:^Mode_Desc,
    $ns:int) -> bool {
    trial(input,st,mode,ns)
    if st.err>=cur_best.err {return false}
    cur_best^=st^
    return true
}

// Moves the endpoints of one subset as if its indices were remapped by
// adjust[0] steps at endpoint 0 and adjust[1] at endpoint 1.
@(private)
linear_transform_endpoints :: proc "contextless" (out,initial:^Endpoints,adjust:[2]f32,min_v,ib,
    sb:int) {
    OLD_MIN :: f32(0)
    OLD_MAX :: f32(1)
    wiggle:=bc67.LERP_FACTOR_4X[ib][1][3]
    new_min:=OLD_MIN+wiggle*adjust[0]
    new_max:=OLD_MAX+wiggle*adjust[1]
    sc:=(OLD_MAX-OLD_MIN)/(new_max-new_min)
    t0:=OLD_MIN+(0-new_min)*sc
    t1:=OLD_MIN+(1-new_min)*sc
    for c in 0..<3 {
        base:=f32(initial.raw[sb+0][c])
        dir:=f32(initial.raw[sb+1][c])-base
        out.raw[sb+0][c]=round_endpoint(base+t0*dir,min_v)
        out.raw[sb+1][c]=round_endpoint(base+t1*dir,min_v)
    }
}

@(private)
try_linear_transforms :: proc "contextless" (input:^Input,st:^Block_State,adjust:[][2]f32,
    mode:^Mode_Desc,$ns:int) {
    IB :: uint(5-ns)
    initial:=st.endpoints
    nst:=st^
    for a in adjust {
        for base:=0;base<ns*2;base+=2 {
            linear_transform_endpoints(&nst.endpoints,&initial,a,0,int(IB),base)
            try_and_commit(input,st,&nst,mode,ns)
        }
    }
}

// Least squares in the space of the half bit patterns, holding the indices.
@(private)
refine_lsq_endpoints :: proc "contextless" (input:^Input,st:^Block_State,$ns:int) {
    IB :: uint(5-ns)
    factors:=&bc67.LERP_FACTOR_4X[IB]
    z00,z10,z11:[2]f32
    q00,t:[2][3]f32
    im:=bc67.SECTION_TBL[ns][st.p]
    for i in 0..<16 {
        s:=im&1
        im>>=2
        f:=&factors[st.idxs[i]&15]
        w:=f[3]
        z00[s]+=f[0]
        z10[s]+=f[1]
        z11[s]+=f[2]
        for c in 0..<3 {
            v:=input.blockf_lsq[i*4+c]
            q00[s][c]+=w*v
            t[s][c]+=v
        }
    }
    for s in 0..<ns {
        det:=z00[s]*z11[s]-z10[s]*z10[s]
        if det==0 {continue}
        det=1/det
        iz00:=z11[s]*det
        iz10:=-z10[s]*det
        iz11:=z00[s]*det
        for c in 0..<3 {
            q0:=q00[s][c]
            q1:=t[s][c]-q0
            st.endpoints.raw[s*2+0][c]=round_endpoint(iz10*q0+iz11*q1,0)
            st.endpoints.raw[s*2+1][c]=round_endpoint(iz00*q0+iz10*q1,0)
        }
    }
}

@(private)
refine_lsq_and_try :: proc "contextless" (input:^Input,st,nst:^Block_State,mode:^Mode_Desc,
    $ns:int) -> bool {
    refine_lsq_endpoints(input,nst,ns)
    return try_and_commit(input,st,nst,mode,ns)
}

@(private)
refine_lsq_iterated :: proc "contextless" (input:^Input,st:^Block_State,iters:int,mode:^Mode_Desc,
    $ns:int) {
    nst:=st^
    for _ in 0..<iters {
        if !refine_lsq_and_try(input,st,&nst,mode,ns) {break}
    }
}

@(private)
refine_lsq_pass :: proc "contextless" (input:^Input,st:^Block_State,iters:int) {
    mode:=&MODE_DESC[st.mode]
    if mode.is_two_subset {refine_lsq_iterated(input,st,iters,mode,
        2)} else {refine_lsq_iterated(input,st,iters,mode,1)}
}

@(private)
refine_jitter_selectors :: proc "contextless" (input:^Input,st:^Block_State,iters:int,
    mode:^Mode_Desc,$ns:int) {
    IB_MASK :: (1<<uint(5-ns))-1
    rs:=input.rand_seed
    for _ in 0..<iters {
        nst:=st^
        ni:=(rand32(&rs)&3)+1
        for _ in 0..<ni {
            r:=rand32(&rs)
            i:=r&15
            j:=int(nst.idxs[i])
            push:=int(u32((u64(r)*5)>>32))-2
            nst.idxs[i]=u8(clamp(j+push,0,IB_MASK))
        }
        refine_lsq_and_try(input,st,&nst,mode,ns)
    }
}

@(rodata,private)
ANNEAL_DIRS := [24][2]int{
    {-2,-2},{-1,-2},{0,-2},{1,-2},{2,-2},
    {-2,-1},{-1,-1},{0,-1},{1,-1},{2,-1},
    {-2,0},{-1,0},{1,0},{2,0},
    {-2,1},{-1,1},{0,1},{1,1},{2,1},
    {-2,2},{-1,2},{0,2},{1,2},{2,2},
}

@(private)
LN2 :: 0.6931471805599453

// rr_exp_approx: 2^t from its integer part and a corrected linear fraction.
@(private)
exp_approx :: proc "contextless" (x:f64) -> f64 {
    t:=x*(1.0/LN2)
    ti:=u64(1023+t)
    tf:=t-f64(ti)+1023
    y:=transmute(f64)(ti<<52)
    y*=1.0+tf+(-0.34168466148744669)*tf*(1.0-tf)
    return y
}

// rrlog2_F64: the exponent of the float plus a Taylor series of the mantissa.
@(private)
log2_approx :: proc "contextless" (X:f64) -> f64 {
    xi:=transmute(u32)f32(X)
    ilog:=int(xi>>23)-127
    frac:=transmute(f32)((xi&((1<<23)-1))|(127<<23))
    k5:f64
    if f64(frac)>4.0/3.0 {
        frac=f32(f64(frac)/2.0)
        ilog+=1
        k5=1/5.0+11.0/(18.0*12.0)
    } else {
        k5=1/5.0-11.0/(18.0*12.0)
    }
    t:=f64(frac)-1.0
    ln_frac:=t-t*t*0.5+(t*t*t)*((1.0/3.0)-t*(1.0/4.0)+t*t*k5)
    return f64(ilog)+ln_frac*(1.0/LN2)
}

@(private)
refine_anneal_endpoints :: proc "contextless" (input:^Input,st:^Block_State,iters:int,
    mode:^Mode_Desc,$ns:int) {
    if st.err==0 || iters==0 {return}
    cb_shift:=uint(max(0,14-mode.epb))
    current:=st^
    rs:=input.rand_seed
    temperature_flt:=f32(1024)
    decay:=f32(exp_approx(-(LN2*log2_approx(f64(temperature_flt))+0.5)/(f64(max(iters,2))-1.0)))
    for _ in 0..<iters {
        temperature:=int(ftoi(temperature_flt))
        temperature_flt*=decay
        for s in 0..<ns {
            part:=current
            which:=rand_mod(&rs,7)+1
            for {
                c:=int(intrinsics.count_trailing_zeros(which))
                which&=which-1
                rnd:=rand_mod(&rs,len(ANNEAL_DIRS))
                e0:=&part.endpoints.raw[s*2+0][c]
                e1:=&part.endpoints.raw[s*2+1][c]
                e0^=i16(clamp(int(e0^)+ANNEAL_DIRS[rnd][0]*(1<<cb_shift),0,0x7bff))
                e1^=i16(clamp(int(e1^)+ANNEAL_DIRS[rnd][1]*(1<<cb_shift),0,0x7bff))
                if which==0 {break}
            }
            trial(input,&part,mode,ns)
            if part.err<current.err || (temperature>0 && rand_mod(&rs,
                u32(temperature))>=current.err-part.err) {
                current=part
                if part.err<st.err {
                    st^=part
                    if st.err==0 {return}
                }
            }
        }
    }
}

@(private)
refine_pca_core :: proc "contextless" (input:^Input,st:^Block_State,flags:Flags,opt:^Enc_Options,
    s:int,inds:u64,num:int,mode:^Mode_Desc,pp:^Partition_Prep,$ns:int) {
    sum_sqr:f32
    min_dot:=max(f32)
    max_dot:=transmute(f32)u32(0x00800000) // FLT_MIN
    mean:=pp.mean[s]
    pca:=pp.pca[s]
    inds:=inds
    for _ in 0..<num {
        i:=int(inds&0xf)
        inds>>=4
        dot:f32
        for c in 0..<3 {dot+=(input.blockf_lsq[i*4+c]-mean[c])*pca[c]}
        sum_sqr+=dot*dot
        min_dot=min_dot<dot ? min_dot : dot
        max_dot=max_dot>dot ? max_dot : dot
    }
    // Shrink slightly so the extremes land nearer the edge of their buckets.
    shrink:=(max_dot-min_dot)*(1.0/64.0)
    smin:=min_dot+shrink
    smax:=max_dot-shrink
    nst:=st^
    for c in 0..<3 {
        nst.endpoints.raw[s*2+0][c]=round_endpoint(mean[c]+pca[c]*smin,0)
        nst.endpoints.raw[s*2+1][c]=round_endpoint(mean[c]+pca[c]*smax,0)
    }
    try_and_commit(input,st,&nst,mode,ns)
    if .Pca_Stretch in flags {
        variance:=sum_sqr/f32(num)
        sdev:=intrinsics.sqrt(variance)*2
        passes:=opt.max_pca_stretch_passes
        base:=0.75*sdev
        step:=0.5/(f32(passes)-1.0)*sdev
        for pass in 0..<passes {
            spread:=base+f32(pass)*step
            for c in 0..<3 {
                delta:=spread*pca[c]
                nst.endpoints.raw[s*2+0][c]=round_endpoint(mean[c]-delta,0)
                nst.endpoints.raw[s*2+1][c]=round_endpoint(mean[c]+delta,0)
            }
            try_and_commit(input,st,&nst,mode,ns)
        }
    }
}

@(private)
refine_pca :: proc "contextless" (input:^Input,st:^Block_State,flags:Flags,opt:^Enc_Options,
    mode:^Mode_Desc,pp:^Partition_Prep,$ns:int) {
    inds:=bc67.SUBSET_TO_INDS[ns-1][st.p]
    for s in 0..<ns {
        num:=int(bc67.NUM_PIXELS_PER_SUBSET[ns][st.p][s])
        refine_pca_core(input,st,flags,opt,s,inds,num,mode,pp,ns)
        inds>>=uint(num*4)
    }
}

@(rodata,private)
EXTRAPOLATE_ADJUST := [3][2]f32{{1,0},{0,-1},{1,-1}}

// Large moves in one direction (3/8) and small roundings (1/16).
@(rodata,private)
SLIDE_ADJUST := [8][2]f32{
    {-1.0/16,-1.0/16},{0,-3.0/8},{1.0/16,-1.0/16},
    {-3.0/8,0},{3.0/8,0},
    {-1.0/16,1.0/16},{0,3.0/8},{1.0/16,1.0/16},
}

@(private)
refine_ns :: proc "contextless" (input:^Input,st:^Block_State,flags:Flags,optiters:[2]int,
    opt:^Enc_Options,mode:^Mode_Desc,pp:^Partition_Prep,$ns:int) {
    if flags&{.Pca,.Pca_Stretch}!={} {refine_pca(input,st,flags,opt,mode,pp,ns)}
    if .Lsq_Fit in flags {refine_lsq_iterated(input,st,opt.max_lsq_iter,mode,ns)}
    if .Extrapolate_Selectors in flags {
        try_linear_transforms(input,st,EXTRAPOLATE_ADJUST[:],mode,ns)
    }
    if .Slide_Selectors in flags {try_linear_transforms(input,st,SLIDE_ADJUST[:],mode,ns)}
    if optiters[0]>0 && .Jitter_Selectors in flags {
        refine_jitter_selectors(input,st,optiters[0],mode,ns)
    }
    if optiters[1]>0 && .Anneal_Endpoints in flags {
        refine_anneal_endpoints(input,st,optiters[1],mode,ns)
    }
}

@(private)
prep_info_of :: #force_inline proc "contextless" (prep:^Prep,mode,p:int) -> ^Prep_Info {
    return MODE_DESC[mode].is_two_subset ? &prep.sub2[p&31] : &prep.sub1
}

@(private)
refine :: proc "contextless" (input:^Input,st:^Block_State,flags:Flags,optiters:[2]int,
    opt:^Enc_Options,prep:^Prep) {
    mode:=&MODE_DESC[st.mode]
    pp:=&prep_info_of(prep,int(st.mode),int(st.p)).prep
    if mode.is_two_subset {
        refine_ns(input,st,flags,optiters,opt,mode,pp,2)
    } else {
        refine_ns(input,st,flags,optiters,opt,mode,pp,1)
    }
}

@(private)
partition :: proc "contextless" (input:^Input,prep:^Prep,results:^Results,flags:Flags,
    opt:^Enc_Options,mode,p:int,endpoints:^Endpoints,$ns:int) -> Error {
    desc:=&MODE_DESC[mode]
    info:=prep_info_of(prep,mode,p)
    st:=Block_State{err=ERROR_MAX,mode=u8(mode),p=u8(p)}
    st.endpoints=endpoints!=nil ? endpoints^ : info.initial_ep
    if !can_fit_mode(&st.endpoints,mode,ns) {return ERROR_MAX}
    trial(input,&st,desc,ns)
    if flags&{.Pca,.Pca_Stretch}!={} {refine_pca(input,&st,flags,opt,desc,&info.prep,ns)}
    results_add(results,&st)
    return st.err
}

@(private)
partitions :: proc "contextless" (input:^Input,prep:^Prep,results:^Results,flags:Flags,
    opt:^Enc_Options,mode:int,$ns:int) {
    num_part:=min(MODE_DESC[mode].is_two_subset ? 32 : 1,opt.max_part)
    for pp:=0;pp<num_part && results.best_err>0;pp+=1 {
        p:=num_part>1 ? PARTITION_ORDER[pp] : 0
        partition(input,prep,results,flags,opt,mode,p,nil,ns)
    }
}

@(rodata,private)
TWO_SUBSET_PRUNE_ORDER := [10]int{2,3,4,0,5,6,7,8,1,9}

@(private)
encode_core :: proc "contextless" (input:^Input,opt:^Enc_Options) -> Block_State {
    prep:Prep
    prep_init(&prep,input,opt)

    seed:Results
    results_init(&seed,opt.narrow0)
    one_flags:=opt.flags
    two_flags:=opt.flags-{.Pca_Stretch}
    if .Aggressive_Mode_Prune in opt.flags {
        one_flags-={.Pca,.Pca_Stretch}
        two_flags-={.Pca,.Pca_Stretch}
    }
    partitions(input,&prep,&seed,one_flags,opt,14,1)
    partitions(input,&prep,&seed,two_flags,opt,15,2)

    enc:Results
    results_init(&enc,opt.narrow1!=0 ? opt.narrow1 : opt.narrow0)
    initial_flags:=opt.flags-{.Pca,.Pca_Stretch}
    for i in 0..<seed.used {
        sd:=&seed.pool[seed.heap[i].slot]
        p:=int(sd.p)
        info:=&prep_info_of(&prep,int(sd.mode),p).prep
        if sd.mode==14 {
            if opt.flags!=one_flags {refine_pca(input,sd,opt.flags,opt,&MODE_DESC[sd.mode],info,1)}
            if .Aggressive_Mode_Prune in opt.flags {
                for mode:=13;mode>=10;mode-=1 {
                    err:=partition(input,&prep,&enc,initial_flags,opt,mode,p,&sd.endpoints,1)
                    if err<ERROR_MAX {break}
                }
            } else {
                for mode in 10..=13 {
                    partition(input,&prep,&enc,initial_flags,opt,mode,p,&sd.endpoints,1)
                }
            }
        } else {
            if opt.flags!=two_flags {refine_pca(input,sd,opt.flags,opt,&MODE_DESC[sd.mode],info,2)}
            if .Aggressive_Mode_Prune in opt.flags {
                for mode in TWO_SUBSET_PRUNE_ORDER {
                    err:=partition(input,&prep,&enc,initial_flags,opt,mode,p,&sd.endpoints,2)
                    if err<ERROR_MAX {break}
                }
            } else {
                for mode in 0..=9 {
                    partition(input,&prep,&enc,initial_flags,opt,mode,p,&sd.endpoints,2)
                }
            }
        }
    }

    if opt.narrow2!=0 {
        for i in 0..<enc.used {refine_lsq_pass(input,&enc.pool[enc.heap[i].slot],3)}
        results_shrink(&enc,opt.narrow2)
    }
    for i in 0..<enc.used {
        refine(input,&enc.pool[enc.heap[i].slot],opt.flags,opt.optiters_early,opt,&prep)
    }

    best:=&enc.pool[enc.heap[0].slot]
    for i in 1..<enc.used {
        slot:=&enc.pool[enc.heap[i].slot]
        if slot.err<best.err {best=slot}
    }
    refine(input,best,opt.flags-{.Pca,.Pca_Stretch},opt.optiters_late,opt,&prep)
    return best^
}

@(private)
remove_anchor_bit :: #force_inline proc "contextless" (idxs,anchor_bit:u64) -> u64 {
    lo:=anchor_bit-1
    return (idxs&lo)|((idxs>>1)&~lo)
}

// Swaps endpoints so the anchor index bits are clear. Delta modes must have
// had the anchor of subset 0 fixed already (fix_delta_endpoint01).
canonicalize :: proc "contextless" (st:^Block_State) {
    mode:=&MODE_DESC[st.mode]
    ns:=mode.is_two_subset ? 2 : 1
    ib:=uint(mode.is_two_subset ? 3 : 4)
    flip_bits:=u8((1<<ib)-1)
    anchor_bit:=u8(1<<(ib-1))
    subset_mask:=bc67.SECTION_TBL[ns][st.p&63]
    if st.idxs[0]&anchor_bit!=0 && mode.db[0]==0 {
        flip_subset_inds(&st.idxs,subset_mask,0,flip_bits)
        swap_endpoints(&st.endpoints,0,1)
    }
    if ns==2 {
        pos:=asset.BC7_ANCHORS_2[st.p&63]
        if st.idxs[pos]&anchor_bit!=0 {
            flip_subset_inds(&st.idxs,subset_mask,1,flip_bits)
            swap_endpoints(&st.endpoints,2,3)
        }
    }
}

@(rodata,private)
BITREV6 := [64]u8{
    0x00,0x20,0x10,0x30,0x08,0x28,0x18,0x38,0x04,0x24,0x14,0x34,0x0c,0x2c,0x1c,0x3c,
    0x02,0x22,0x12,0x32,0x0a,0x2a,0x1a,0x3a,0x06,0x26,0x16,0x36,0x0e,0x2e,0x1e,0x3e,
    0x01,0x21,0x11,0x31,0x09,0x29,0x19,0x39,0x05,0x25,0x15,0x35,0x0d,0x2d,0x1d,0x3d,
    0x03,0x23,0x13,0x33,0x0b,0x2b,0x1b,0x3b,0x07,0x27,0x17,0x37,0x0f,0x2f,0x1f,0x3f,
}

// The bits of a canonical state.
emit :: proc "contextless" (out:^[16]u8,st:^Block_State) {
    m:=int(st.mode)
    if m>13 {
        out^={}
        return
    }
    mode:=&MODE_DESC[m]
    ns:=mode.is_two_subset ? 2 : 1
    ib:=uint(mode.is_two_subset ? 3 : 4)
    e:[4][3]i64
    for i in 0..<ns*2 {
        for c in 0..<3 {
            e[i][c]=i64(st.endpoints.quant[i][c])
            if mode.db[0]!=0 && i!=0 {e[i][c]-=e[0][c]}
        }
    }
    idxs:u64
    for i in 0..<16 {idxs|=u64(st.idxs[i])<<(uint(i)*ib)}
    anchor0:=u64(1)<<(ib-1)
    anchor1:=u64(1)<<(ib*(uint(asset.BC7_ANCHORS_2[st.p&63])+1)-1)
    idxs=remove_anchor_bit(idxs,anchor0)
    if ns>=2 {
        anchor1>>=1
        idxs=remove_anchor_bit(idxs,anchor1)
    }
    U :: #force_inline proc "contextless" (x:i64) -> u64 {return u64(x)}
    lo,hi:u64
    if m<2 {lo=u64(m)} else {lo=u64(((m+14)>>3)+(((m-2)&7)<<2))}
    lo|=U(e[0][0]&0x3ff)<<5
    lo|=U(e[0][1]&0x3ff)<<15
    lo|=U(e[0][2]&0x3ff)<<25
    if ns==2 {
        lo|=U(e[1][0]&0x3f)<<35
        lo|=U(e[2][1]&0xf)<<41
        lo|=U(e[1][1]&0x3f)<<45
        lo|=U(e[3][1]&0xf)<<51
        lo|=U(e[1][2]&0x3f)<<55
        lo|=U(e[2][2]&0xf)<<61
        hi=U((e[2][2]>>3)&1)<<0
        hi|=U(e[2][0]&0x3f)<<(65-64)
        hi|=U(e[3][0]&0x3f)<<(71-64)
        hi|=u64(st.p)<<(77-64)
        hi|=idxs<<(82-64)
    } else {
        lo|=U(e[1][0]&0x3ff)<<35
        lo|=U(e[1][1]&0x3ff)<<45
        lo|=U(e[1][2])<<55
        hi=U(e[1][2]>>9)&1
        hi|=idxs<<1
    }
    switch m {
    case 0: lo&=0xEFFBFEFFFFFFFFE3; hi&=0xFFFFFFFFFFFFEFBF
    case 1: lo&=0xFFFFFFF8FE3F8FE3
    case 2: lo&=0xE7F9FEFFFFFFFFFF; hi&=0xFFFFFFFFFFFFEFBF
    case 3: lo&=0xE7FBFE7FFFFFFFFF; hi&=0xFFFFFFFFFFFFE79F
    case 4: lo&=0xEFF9FE7FFFFFFFFF; hi&=0xFFFFFFFFFFFFE79F
    case 5: lo&=0xEFFBFEFBFEFFBFFF; hi&=0xFFFFFFFFFFFFEFBF
    case 6: lo&=0xEFFBFFF9FE7F9FFF
    case 7: lo&=0xEFFFFEF9FE7F9FFF; hi&=0xFFFFFFFFFFFFEFBF
    case 8: lo&=0xFFFBFEF9FE7F9FFF; hi&=0xFFFFFFFFFFFFEFBF
    case 9: lo&=0xFFFFFFF87E1F87FF
    case 11: lo&=0xFFBFEFFFFFFFFFFF; hi&=0xFFFFFFFFFFFFFFFE
    case 12: lo&=0x7F9FE7FFFFFFFFFF; hi&=0xFFFFFFFFFFFFFFFE
    case 13: lo&=0x0781E07FFFFFFFFF; hi&=0xFFFFFFFFFFFFFFFE
    }
    B :: #force_inline proc "contextless" (x:i64,shift:uint,
        mask:i64) -> u64 {return U((x>>shift)&mask)}
    if m==1 || (m>=5 && m<=9) {
        lo|=B(e[2][2],4,1)<<14
        lo|=B(e[2][1],4,1)<<24
        lo|=B(e[3][2],4,1)<<34
    }
    if m==1 || m==6 || m==9 {lo|=B(e[3][2],2,1)<<23}
    if m==3 || m==4 {lo|=B(e[0][0],10,1)<<39}
    if m==0 || m==3 || m==5 || m==7 || m==8 {
        lo|=B(e[3][1],4,1)<<40
    } else if m==4 {
        lo|=B(e[2][2],4,1)<<40
    } else if m==2 {
        lo|=B(e[0][0],10,1)<<40
    }
    if m==2 || m==4 {lo|=B(e[0][1],10,1)<<49}
    if m==0 || m==2 || m==4 || m==5 || m==6 || m==8 {lo|=B(e[3][2],0,1)<<50}
    if m==2 || m==3 {lo|=B(e[0][2],10,1)<<59}
    if m==0 || m==2 || m==3 || m==5 || m==6 || m==7 {
        lo|=B(e[3][2],1,1)<<60
    } else if m==4 {
        lo|=B(e[0][2],10,1)<<60
    }
    if m==0 || m==2 || m==3 || m==4 || m==5 || m==7 || m==8 {
        hi|=B(e[3][2],2,1)<<(70-64)
        hi|=B(e[3][2],3,1)<<(76-64)
    }
    switch m {
    case 0:
        lo|=B(e[2][1],4,1)<<2
        lo|=B(e[2][2],4,1)<<3
        lo|=B(e[3][2],4,1)<<4
    case 1:
        lo|=B(e[2][1],5,1)<<2
        lo|=B(e[3][1],4,3)<<3
        lo|=B(e[3][2],0,3)<<12
        lo|=B(e[2][2],5,1)<<22
        lo|=B(e[3][2],3,1)<<32
        lo|=B(e[3][2],5,1)<<33
    case 3:
        lo|=B(e[0][1],10,1)<<50
        hi|=B(e[3][2],0,1)<<(69-64)
        hi|=B(e[2][1],4,1)<<(75-64)
    case 4:
        hi|=B(e[3][2],1,1)<<(69-64)
        hi|=B(e[3][2],4,1)<<(75-64)
    case 6:
        lo|=B(e[3][1],4,1)<<13
        lo|=B(e[3][2],3,3)<<33
    case 7:
        lo|=B(e[3][2],0,1)<<13
        lo|=B(e[2][1],5,1)<<23
        lo|=B(e[3][1],5,1)<<33
    case 8:
        lo|=B(e[3][2],1,1)<<13
        lo|=B(e[2][2],5,1)<<23
        lo|=B(e[3][2],5,1)<<33
    case 9:
        lo|=B(e[3][1],4,1)<<11
        lo|=B(e[3][2],0,3)<<12
        lo|=B(e[2][1],5,1)<<21
        lo|=B(e[2][2],5,1)<<22
        lo|=B(e[3][1],5,1)<<31
        lo|=B(e[3][2],3,1)<<32
        lo|=B(e[3][2],5,1)<<33
    case 12:
        lo|=B(e[0][0],11,1)<<43
        lo|=B(e[0][1],11,1)<<53
        lo|=B(e[0][2],11,1)<<63
        fallthrough
    case 11:
        lo|=B(e[0][0],10,1)<<44
        lo|=B(e[0][1],10,1)<<54
        hi|=B(e[0][2],10,1)<<(64-64)
    case 13:
        lo|=u64(BITREV6[(e[0][0]>>10)&0x3f])<<39
        lo|=u64(BITREV6[(e[0][1]>>10)&0x3f])<<49
        lo|=u64(BITREV6[(e[0][2]>>10)&0x3f])<<59
        hi|=B(e[0][2],10,1)<<(64-64)
    }
    for i in 0..<8 {
        out[i]=u8(lo>>(uint(i)*8))
        out[8+i]=u8(hi>>(uint(i)*8))
    }
}

// Mode 13 with both endpoints at the color: the closest a block can get.
encode_single_color_block :: proc "contextless" (out:^[16]u8,color:[4]u16) {
    st:Block_State
    st.mode=13
    for c in 0..<3 {
        v:=i16(clamp(int(color[c]),0,0x7bff))
        st.endpoints.raw[0][c]=v
        st.endpoints.raw[1][c]=v
    }
    quantize_endpoints(&st.endpoints,&MODE_DESC[13],1)
    emit(out,&st)
}

// Infinity becomes the largest half, NaN and negatives 0; alpha 1.0.
canonicalize_pixels :: proc "contextless" (blk:^[16][4]u16) {
    for &t in blk {
        for c in 0..<3 {
            x:=t[c]
            t[c]=x<0x7c00 ? x : x==0x7c00 ? 0x7bff : 0
        }
        t[3]=0x3c00
    }
}

options_init :: proc "contextless" (level:common.Level,options:common.Options) -> (o:Enc_Options) {
    o={max_part=32,narrow0=32,narrow1=8,narrow2=4,max_lsq_iter=4,max_pca_stretch_passes=4}
    switch level {
    case .Very_Fast:
        o.flags={.Aggressive_Mode_Prune,.Pca}
        o.narrow0,o.narrow1,o.narrow2,o.max_part=3,1,1,6
    case .Fast:
        o.flags={.Aggressive_Mode_Prune,.Pca_Stretch}
        o.narrow0,o.narrow1,o.narrow2,o.max_part=5,0,1,10
    case .Slow:
        o.flags={.Pca_Stretch,.Extrapolate_Selectors,.Slide_Selectors,.Jitter_Selectors}
        o.narrow0,o.narrow1,o.narrow2,o.max_part=5,3,1,16
        o.optiters_early[0]=3
        o.optiters_late[0]=9
    case .Very_Slow:
        o.flags={.Pca_Stretch,.Lsq_Fit,.Extrapolate_Selectors,.Slide_Selectors,.Jitter_Selectors}
        o.narrow0,o.narrow1,o.narrow2,o.max_part=10,4,2,32
        o.optiters_early[0]=6
        o.optiters_late[0]=30
    case .Reference:
        o.flags={.Pca_Stretch,.Lsq_Fit,.Extrapolate_Selectors,.Slide_Selectors,.Jitter_Selectors,
            .Anneal_Endpoints}
        o.narrow0,o.narrow1,o.narrow2=12,10,8
        o.max_lsq_iter=100
        o.optiters_early={16,48}
        o.optiters_late={64,64}
    }
    if .BC6_Favor_Luminance in options {o.flags+={.Weighted_Channels}}
    return
}

// The random seed of a block: the red and green halfs of its texels.
seed_of :: proc "contextless" (blk:^[16][4]u16) -> Rand_State {
    rs:=RAND_INIT
    G :: #force_inline proc "contextless" (t:[4]u16) -> u32 {return u32(t[0])|u32(t[1])<<16}
    for i:=0;i<16;i+=4 {
        rs.c~=G(blk[i+0])
        rs.x~=G(blk[i+1])
        rs.y~=G(blk[i+2])
        rs.z~=G(blk[i+3])
        rand32(&rs)
    }
    return rs
}

compress_block :: proc "contextless" (out:^[16]u8,in_block:^[16][4]u16,opt:^Enc_Options) {
    blk:=in_block^
    canonicalize_pixels(&blk)
    one:=true
    for i in 1..<16 {
        if blk[i][0]!=blk[0][0] || blk[i][1]!=blk[0][1] || blk[i][2]!=blk[0][2] {one=false;break}
    }
    if one {
        encode_single_color_block(out,blk[0])
        return
    }
    rs:=RAND_INIT
    if opt.flags&{.Jitter_Selectors,.Anneal_Endpoints}!={} {rs=seed_of(&blk)}
    input:Input
    input_init(&input,&blk,rs,opt.flags)
    best:=encode_core(&input,opt)
    canonicalize(&best)
    emit(out,&best)
}

// Encodes half float RGBA blocks to BC6U; len(to) must be 16 bytes per block.
compress :: proc(to:[]u8,from:[]common.Half_Block,level:common.Level,
    options:common.Options) -> common.Error {
    if len(to)<len(from)*16 {return .Invalid}
    opt:=options_init(level,options)
    for &b,i in from {
        compress_block((^[16]u8)(&to[i*16]),&b,&opt)
    }
    return .None
}

// The state of a well-formed block; false (and a zero state) otherwise.
state_from_bits :: proc "contextless" (st:^Block_State,bits:^[16]u8) -> bool {
    fields,ok:=asset.texture_bc6h_block_fields(bits^)
    if !ok {
        st^={}
        return false
    }
    modes:=asset.BC6H_MODES
    st.mode=u8(fields.mode)
    st.p=u8(fields.partition)
    st.err=0
    st.idxs=fields.indices
    for i in 0..<int(modes[fields.mode].ns)*2 {
        for c in 0..<3 {
            st.endpoints.quant[i][c]=fields.quant[c][i]
            st.endpoints.raw[i][c]=i16(u16(scaled_to_half(int(fields.endpoints[c][i]))))
        }
    }
    return true
}

// The error of the endpoints and indices of st.
eval_error :: proc "contextless" (st:^Block_State,input:^Input) -> Error {
    set:Color_Set
    mode:=&MODE_DESC[st.mode&15]
    if mode.is_two_subset {
        color_set_init(&set,&st.endpoints,mode,input.channel_weights_sqrt,2)
        return eval_indexes(input,st,&set,2)
    }
    color_set_init(&set,&st.endpoints,mode,input.channel_weights_sqrt,1)
    return eval_indexes(input,st,&set,1)
}

// New indices for the endpoints of st, anchors kept clear; their error.
reindex_block :: proc "contextless" (st:^Block_State,input:^Input) -> Error {
    set:Color_Set
    mode:=&MODE_DESC[st.mode&15]
    if mode.is_two_subset {
        color_set_init(&set,&st.endpoints,mode,input.channel_weights_sqrt,2)
        return calc_indexes_anchor_zero(input,st,&set,2)
    }
    color_set_init(&set,&st.endpoints,mode,input.channel_weights_sqrt,1)
    return calc_indexes_anchor_zero(input,st,&set,1)
}

// New endpoints by least squares for the indices of st; their error.
new_endpoints_with_indices_fixed :: proc "contextless" (st:^Block_State,input:^Input) -> Error {
    set:Color_Set
    mode:=&MODE_DESC[st.mode&15]
    if mode.is_two_subset {
        refine_lsq_endpoints(input,st,2)
        calc_endpoints(&st.endpoints,mode,2)
        color_set_init(&set,&st.endpoints,mode,input.channel_weights_sqrt,2)
        st.err=eval_indexes(input,st,&set,2)
    } else {
        refine_lsq_endpoints(input,st,1)
        calc_endpoints(&st.endpoints,mode,1)
        color_set_init(&set,&st.endpoints,mode,input.channel_weights_sqrt,1)
        st.err=eval_indexes(input,st,&set,1)
    }
    return st.err
}
