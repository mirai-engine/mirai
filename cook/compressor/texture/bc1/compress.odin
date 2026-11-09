package bc1

import "base:intrinsics"
import "core:simd"
import "mirai:cook/compressor/texture/bc67"
import "mirai:cook/compressor/texture/common"

// BC1 blocks and the color half of BC3: endpoint candidates from a single color fit, the
// bounding box and a 4-means clustering along the principal axis, refined by least squares
// on the indices, annealing and greedy steps of one quantization level.

Color :: common.Color
Color_Block :: common.Color_Block
BC1_Block :: common.BC1_Block
Palette_Mode :: common.BC1_Palette_Mode
Unpacked_565 :: common.Unpacked_565
Endpoints :: [2]Unpacked_565
Vec3i :: common.Vec3i
Vec3f :: common.Vec3f

B :: common.B
G :: common.G
R :: common.R
A :: common.A

INIT_ERROR :: common.DXTC_ERROR_BIG

@(private)
Startup_Data :: struct {
    avg:Vec3i,
    diagonal:Vec3i,
    sum:Vec3i,
    lo:Color,
    hi:Color,
    // only with Alpha: the block has transparent texels, so it must use three colors
    has_any_alpha:bool,
}

// Candidate endpoint pairs; appends past the capacity are dropped.
@(private)
Endpoint_List :: struct {
    eps:[70]Endpoints,
    n:int,
}

@(private)
push :: #force_inline proc "contextless" (l:^Endpoint_List,ep:Endpoints) {
    if l.n<len(l.eps) {
        l.eps[l.n]=ep
        l.n+=1
    }
}

@(private)
add_single_color_compact_4c :: proc "contextless" (eps:^Endpoint_List,c:Color) {
    opt_r:=bc67.BC1_OPTIMAL_4C[0][c[R]]
    opt_g:=bc67.BC1_OPTIMAL_4C[1][c[G]]
    opt_b:=bc67.BC1_OPTIMAL_4C[0][c[B]]
    ep:=Endpoints{common.unpacked_565_make(opt_r.lo,opt_g.lo,opt_b.lo),
        common.unpacked_565_make(opt_r.hi,opt_g.hi,opt_b.hi)}
    if ep[0]<ep[1] {ep[0],ep[1]=ep[1],ep[0]}
    push(eps,ep)
}

@(private)
add_single_color_compact_3c :: proc "contextless" (eps:^Endpoint_List,c:Color) {
    opt_r:=bc67.BC1_OPTIMAL_3C[0][c[R]]
    opt_g:=bc67.BC1_OPTIMAL_3C[1][c[G]]
    opt_b:=bc67.BC1_OPTIMAL_3C[0][c[B]]
    ep:=Endpoints{common.unpacked_565_make(opt_r.lo,opt_g.lo,opt_b.lo),
        common.unpacked_565_make(opt_r.hi,opt_g.hi,opt_b.hi)}
    if ep[0]>ep[1] {ep[0],ep[1]=ep[1],ep[0]}
    push(eps,ep)
}

@(private)
add_default :: proc "contextless" (eps:^Endpoint_List,mode:Palette_Mode,end1,end2:Color) {
    ep:=Endpoints{common.unpacked_565_quantize(end1),common.unpacked_565_quantize(end2)}
    if ep[0]==ep[1] {return}
    push(eps,ep)
    if mode!=.Four_Color {push(eps,Endpoints{ep[1],ep[0]})}
}

@(private)
add_force_3c :: proc "contextless" (eps:^Endpoint_List,end1,end2:Color) {
    ep:=Endpoints{common.unpacked_565_quantize(end1),common.unpacked_565_quantize(end2)}
    if ep[0]>ep[1] {ep[0],ep[1]=ep[1],ep[0]}
    push(eps,ep)
}

@(private)
add_both_ways :: proc "contextless" (eps:^Endpoint_List,end1,end2:Color) {
    ep:=Endpoints{common.unpacked_565_quantize(end1),common.unpacked_565_quantize(end2)}
    if ep[0]==ep[1] {return}
    push(eps,ep)
    push(eps,Endpoints{ep[1],ep[0]})
}

@(private)
vec3i_to_color_clamp :: #force_inline proc "contextless" (v:Vec3i) -> Color {
    return {common.clamp_u8(v.x),common.clamp_u8(v.y),common.clamp_u8(v.z),255}
}

@(private)
add_two_color_best :: proc "contextless" (eps:^Endpoint_List,c1,c2:Color) {
    v1:=common.color_to_vec3i(c1)
    v2:=common.color_to_vec3i(c2)
    delta:=v2-v1
    add_both_ways(eps,c1,c2)
    delta2:=Vec3i{delta.x/2,delta.y/2,delta.z/2}
    if common.vec3i_dot(delta2,delta2)<6 {return}
    add_both_ways(eps,vec3i_to_color_clamp(v1-delta),vec3i_to_color_clamp(v2+delta))
    cend1:=vec3i_to_color_clamp(v1-delta2)
    cend2:=vec3i_to_color_clamp(v2+delta2)
    add_both_ways(eps,cend1,c2)
    add_both_ways(eps,c1,cend2)
}

@(private)
average :: #force_inline proc "contextless" (c1,c2:Color) -> Color {
    return {
        u8((u32(c1[B])+u32(c2[B]))>>1),u8((u32(c1[G])+u32(c2[G]))>>1),
        u8((u32(c1[R])+u32(c2[R]))>>1),255,
    }
}

@(private)
Filter_Allow :: enum u8 {Four_Color,Three_Color}

// Keeps only the endpoints of the allowed modes, in place.
@(private)
filter_endpoints :: proc "contextless" (eps:[]Endpoints,allow:bit_set[Filter_Allow]) -> int {
    if allow=={} {return 0}
    if allow=={.Four_Color,.Three_Color} {return len(eps)}
    want_4color:=allow=={.Four_Color}
    n:=0
    for ep in eps {
        if (ep[0]>ep[1])==want_4color {
            eps[n]=ep
            n+=1
        }
    }
    return n
}

// Takes the best of the candidates when it beats err.
@(private)
try_batched_endpoints :: proc "contextless" (block:^BC1_Block,err:^u32,colors:^Color_Block,
    mode:Palette_Mode,eps:[]Endpoints,palettes:[][4]Color) {
    count:=min(len(eps),len(palettes),common.BC1_FIND_ERRORS_COUNT_LIMIT-1)
    if count==0 {return}
    ctx:common.BC1_Find_Errors_Context
    common.bc1_find_errors_init(&ctx,colors)
    common.bc1_palettes_batched(eps[:count],palettes[:count],mode)
    best_err_and_i:=common.bc1_find_best_palette(&ctx,palettes[:count])
    best_err:=best_err_and_i>>common.BC1_FIND_ERRORS_COUNT_SHIFT
    if best_err<err^ {
        best_i:=best_err_and_i&(common.BC1_FIND_ERRORS_COUNT_LIMIT-1)
        block.endpoints=common.bc1_make_endpoints(common.unpacked_565_pack(eps[best_i][0]),
            common.unpacked_565_pack(eps[best_i][1]))
        block.indices=common.bc1_find_indices_palette(colors,&palettes[best_i],err)
    }
}

@(private)
is_transparent_or_black :: #force_inline proc "contextless" (mode:Palette_Mode,c:Color) -> bool {
    switch mode {
    case .Four_Color: return false
    case .Alpha: return common.is_one_bit_transparent(c)
    case .No_Alpha:
        BLACKNESS_DISTANCE :: 12
        return c[B]<BLACKNESS_DISTANCE && c[G]<BLACKNESS_DISTANCE && c[R]<BLACKNESS_DISTANCE
    }
    return false
}

@(private)
startup_impl :: proc "contextless" (data:^Startup_Data,colors:^Color_Block,mode:Palette_Mode,
    eps:^Endpoint_List) -> bool {
    avg:Vec3i
    lo:=Color{255,255,255,0}
    hi:=Color{0,0,0,0}
    num_colors:=0
    lo_colors:=Color{255,255,255,0}
    hi_colors:=Color{0,0,0,0}
    num_transparent:=0
    for i in 0..<16 {
        c:=colors[i]
        if common.color_dw(c)==0 {num_transparent+=1}
        avg+=common.color_to_vec3i(c)
        for k in 0..<3 {
            hi[k]=max(hi[k],c[k])
            lo[k]=min(lo[k],c[k])
        }
        if !is_transparent_or_black(mode,c) {
            num_colors+=1
            for k in 0..<3 {
                hi_colors[k]=max(hi_colors[k],c[k])
                lo_colors[k]=min(lo_colors[k],c[k])
            }
        }
    }
    if common.color_dw(hi)==0 {
        push(eps,Endpoints{0,0})
        return false
    }
    data.has_any_alpha=num_transparent>0
    sum:=avg
    avg.x=(avg.x+8)>>4
    avg.y=(avg.y+8)>>4
    avg.z=(avg.z+8)>>4
    avg_c:=common.vec3i_to_color(avg)
    if !data.has_any_alpha {add_single_color_compact_4c(eps,avg_c)}
    if num_colors<16 {
        if num_colors==0 {
            lo_colors=lo
            hi_colors=hi
        }
        add_single_color_compact_3c(eps,average(lo_colors,hi_colors))
        if common.color_dw(lo_colors)!=common.color_dw(hi_colors) {add_force_3c(eps,lo_colors,
            hi_colors)}
    }
    if common.color_dw(lo)==common.color_dw(hi) {return false}
    diagonal:=common.color_to_vec3i(hi)-common.color_to_vec3i(lo)
    if common.vec3i_dot(diagonal,diagonal)<=12 {
        add_default(eps,mode,lo,hi)
        return false
    }
    data.avg=avg
    data.diagonal=diagonal
    data.sum=sum
    data.lo=lo
    data.hi=hi
    return true
}

// False for degenerate blocks that need no more search.
@(private)
startup :: proc "contextless" (data:^Startup_Data,block:^BC1_Block,err:^u32,colors:^Color_Block,
    mode:Palette_Mode) -> bool {
    eps:Endpoint_List
    result:=startup_impl(data,colors,mode,&eps)
    palettes:[16][4]Color
    try_batched_endpoints(block,err,colors,mode,eps.eps[:min(eps.n,16)],palettes[:])
    return result
}

@(private)
Means_Flag :: enum u8 {PCA,Reduced_Candidates}

// The vector order: lanes B, G, R, A (A forced to 255, so its deviations are 0).
@(private)
calc_4means :: proc "contextless" (means:^[4]Color,data:^Startup_Data,colors:^Color_Block,
    flags:bit_set[Means_Flag]) {
    F :: #simd[4]f32
    THIRD:f32:1.0/3.0
    across :: #force_inline proc "contextless" (v:F) -> f32 {
        return (simd.extract(v,0)+simd.extract(v,2))+(simd.extract(v,1)+simd.extract(v,3))
    }
    texel :: #force_inline proc "contextless" (c:Color) -> F {
        return F{f32(c[B]),f32(c[G]),f32(c[R]),255}
    }
    avg:=F{f32(data.sum.x),f32(data.sum.y),f32(data.sum.z),f32(16*255)}*F(1.0/16.0)
    pca:F
    if .PCA in flags {
        cov0,cov1:F
        longest_len2:f32
        for i in 0..<16 {
            d:=texel(colors[i])-avg
            d2:=d*d
            cov0+=d2
            cov1+=d*simd.shuffle(d,d,1,2,0,3)
            len2:=across(d2)
            if len2>longest_len2 {
                pca=d
                longest_len2=len2
            }
        }
        cov2:=simd.shuffle(cov1,cov1,2,0,1,3)
        for _ in 0..<4 {
            pca=pca*cov0+simd.shuffle(pca,pca,1,2,0,3)*cov1+simd.shuffle(pca,pca,2,0,1,3)*cov2
            pca=pca*cov0+simd.shuffle(pca,pca,1,2,0,3)*cov1+simd.shuffle(pca,pca,2,0,1,3)*cov2
            len_sq:=across(pca*pca)
            if len_sq>0 {
                pca=pca/F(common_sqrt(len_sq))
            } else {
                pca={}
            }
        }
    } else {
        diag:=F{f32(data.diagonal.x),f32(data.diagonal.y),f32(data.diagonal.z),0}
        len_sq:=across(diag*diag)
        if len_sq>0 {pca=diag/F(common_sqrt(len_sq))}
    }
    min_dot:=max(f32)
    neg_max_dot:=max(f32)
    for i in 0..<16 {
        dot:=across((texel(colors[i])-avg)*pca)
        min_dot=min(min_dot,dot)
        neg_max_dot=min(neg_max_dot,-dot)
    }
    m0:=avg+pca*F(min_dot*0.75)
    m3:=avg+pca*F(neg_max_dot*-0.75)
    sd:=(m3-m0)*F(THIRD)
    mf:=[4]F{m0,m0+sd,m3-sd,m3}
    for i in 0..<4 {
        q:=simd.clamp(common.round_to_int4(transmute(common.V4f32)mf[i]),common.V4i32(0),
            common.V4i32(255))
        means[i]=transmute(Color)cast(#simd[4]u8)q
    }
}

@(private)
common_sqrt :: #force_inline proc "contextless" (x:f32) -> f32 {return intrinsics.sqrt(x)}

@(private)
four_means :: proc "contextless" (data:^Startup_Data,block:^BC1_Block,err:^u32,colors:^Color_Block,
    mode:Palette_Mode,flags:bit_set[Means_Flag]) -> bool {
    means:[4]Color
    calc_4means(&means,data,colors,flags)
    common.bc1_solve_rgb_4means(&means,colors)
    for i in 0..<4 {means[i][A]=255}
    eps:Endpoint_List
    if .Reduced_Candidates in flags {
        add_both_ways(&eps,means[0],means[1])
        add_both_ways(&eps,means[0],means[2])
        add_both_ways(&eps,means[0],means[3])
        add_both_ways(&eps,means[1],means[2])
        add_both_ways(&eps,means[1],means[3])
        add_both_ways(&eps,means[2],means[3])
    } else {
        add_two_color_best(&eps,means[0],means[3])
        add_two_color_best(&eps,means[1],means[2])
        add_two_color_best(&eps,means[0],means[2])
        add_two_color_best(&eps,means[1],means[3])
        add_two_color_best(&eps,means[0],means[1])
        add_two_color_best(&eps,means[2],means[3])
        add_two_color_best(&eps,average(means[0],means[1]),average(means[2],means[3]))
    }
    allow:bit_set[Filter_Allow]
    if data.has_any_alpha {
        allow={.Three_Color}
    } else if .Reduced_Candidates in flags {
        allow={.Four_Color}
    } else {
        allow={.Four_Color,.Three_Color}
    }
    count:=filter_endpoints(eps.eps[:eps.n],allow)
    palettes:[70][4]Color
    try_batched_endpoints(block,err,colors,mode,eps.eps[:count],palettes[:])
    return true
}

@(private)
NUM_WIGGLES :: 6

@(rodata,private)
WIGGLE_DELTA := [8]i32{1<<16,-(1<<16),1<<8,-(1<<8),1,-1,0,0}

@(private)
wiggle :: #force_inline proc "contextless" (c:Unpacked_565,how:int) -> Unpacked_565 {
    dw:=u32(c)+u32(WIGGLE_DELTA[how&7])
    return (dw&~u32(0xFF1F3F1F))!=0?c:Unpacked_565(dw)
}

@(private)
greedy_optimize_inner :: proc "contextless" (data:^Startup_Data,block:^BC1_Block,err:^u32,
    colors:^Color_Block,mode:Palette_Mode,joint:bool) {
    best0:=common.unpacked_565_from_packed(common.bc1_c0(block^))
    best1:=common.unpacked_565_from_packed(common.bc1_c1(block^))
    ctx:common.BC1_Find_Errors_Context
    common.bc1_find_errors_init(&ctx,colors)
    for {
        start0:=best0
        start1:=best1
        MAX_TRIALS :: 7*7
        eps:[MAX_TRIALS]Endpoints
        count:=0
        if joint {
            for w1 in 0..=NUM_WIGGLES {
                c0:=wiggle(start0,w1)
                for w2 in 0..=NUM_WIGGLES {
                    c1:=wiggle(start1,w2)
                    if c0==start0 && c1==start1 {continue}
                    if data.has_any_alpha && c0>c1 {continue}
                    eps[count]={c0,c1}
                    count+=1
                }
            }
        } else {
            for w1 in 0..<NUM_WIGGLES {
                c0:=wiggle(start0,w1)
                if c0==start0 {continue}
                if data.has_any_alpha && c0>start1 {continue}
                eps[count]={c0,start1}
                count+=1
            }
            for w2 in 0..<NUM_WIGGLES {
                c1:=wiggle(start1,w2)
                if c1==start1 {continue}
                if data.has_any_alpha && start0>c1 {continue}
                eps[count]={start0,c1}
                count+=1
            }
        }
        palettes:[MAX_TRIALS][4]Color
        common.bc1_palettes_batched(eps[:count],palettes[:count],mode)
        best_err_and_i:=common.bc1_find_best_palette(&ctx,palettes[:count])
        best_err:=best_err_and_i>>common.BC1_FIND_ERRORS_COUNT_SHIFT
        if best_err<err^ {
            best_i:=best_err_and_i&(common.BC1_FIND_ERRORS_COUNT_LIMIT-1)
            err^=best_err
            best0=eps[best_i][0]
            best1=eps[best_i][1]
            block.endpoints=common.bc1_make_endpoints(common.unpacked_565_pack(best0),
                common.unpacked_565_pack(best1))
            if best_err==0 {return}
        } else {
            break
        }
    }
}

@(private)
greedy_optimize :: proc "contextless" (data:^Startup_Data,block:^BC1_Block,err:^u32,
    colors:^Color_Block,mode:Palette_Mode,joint:bool) {
    if err^==0 {return}
    orig:=err^
    greedy_optimize_inner(data,block,err,colors,mode,joint)
    if err^!=orig {
        palette:[4]Color
        common.bc1_palette(block.endpoints,&palette,mode)
        block.indices=common.bc1_find_indices_palette(colors,&palette)
    }
}

@(private)
rand64_seed_from_u64s :: proc "contextless" (vals:[]u64) -> u64 {
    state:u64=0x9E3779B97F4A7C15
    for v0 in vals {
        v:=v0*0xBF58476D1CE4E5B9
        v~=(state>>43)|(state<<21)
        state*=0x94D049BB133111EB
        state~=v
    }
    z:=state+0x9E3779B97F4A7C15
    z=(z~(z>>30))*0xBF58476D1CE4E5B9
    z=(z~(z>>27))*0x94D049BB133111EB
    return z~(z>>31)
}

@(private)
rand64 :: #force_inline proc "contextless" (state:^u64) -> u64 {
    z:=state^+0x9E3779B97F4A7C15
    state^=z
    z=(z~(z>>30))*0xBF58476D1CE4E5B9
    z=(z~(z>>27))*0x94D049BB133111EB
    return z~(z>>31)
}

// Moves one channel of one endpoint by one step, clamped to its range: control bits 1..2
// pick R, G or B (3 nothing), bit 0 the sign.
// wiggle_clamped of four endpoints at once, the control of each in bits shift..shift+2 of
// its byte replicated 4 times.
@(private)
wiggle4 :: #force_inline proc "contextless" (colors:#simd[4]i32,control:#simd[16]u8,
    $shift:u8) -> #simd[4]i32 {
    V16 :: #simd[16]u8
    sign_bit:=V16(1<<shift)
    sign_mask:=transmute(V16)simd.lanes_eq(control&sign_bit,sign_bit)
    C :: V16{4<<shift,2<<shift,0,255,4<<shift,2<<shift,0,255,4<<shift,2<<shift,0,255,4<<shift,
        2<<shift,0,255}
    neg0:=transmute(V16)simd.lanes_eq(control&V16(6<<shift),C)
    neg:=(neg0~sign_mask)-sign_mask
    w:=transmute(V16)colors-neg
    w=transmute(V16)simd.max(transmute(#simd[16]i8)w,0)
    w=simd.min(w,V16{31,63,31,0,31,63,31,0,31,63,31,0,31,63,31,0})
    return transmute(#simd[4]i32)w
}

@(private)
anneal :: proc "contextless" (data:^Startup_Data,block:^BC1_Block,err:^u32,colors:^Color_Block,
    mode:Palette_Mode) {
    cur0_init:=common.unpacked_565_from_packed(common.bc1_c0(block^))
    cur1_init:=common.unpacked_565_from_packed(common.bc1_c1(block^))
    initial_error:=err^
    best:=Endpoints{cur0_init,cur1_init}
    seed_vals:=transmute([8]u64)colors^
    rand_state:=rand64_seed_from_u64s(seed_vals[:])
    NITER :: 256
    rng:[NITER]u8
    for i:=0;i<NITER;i+=8 {
        r:=rand64(&rand_state)
        for k in 0..<8 {rng[i+k]=u8(r>>(u64(k)*8))}
    }
    ctx:common.BC1_Find_Errors_Context
    common.bc1_find_errors_init(&ctx,colors)
    THRESHOLD_BASE :: 253
    THRESHOLD_STEP :: 4
    V4i :: #simd[4]i32
    V4u :: #simd[4]u32
    V16 :: #simd[16]u8
    cur0:=V4i(i32(cur0_init))
    cur1:=V4i(i32(cur1_init))
    cur_err:=V4i(i32(initial_error))
    cur_best_err:=V4i(i32(err^))
    thresh:=V4i(THRESHOLD_BASE)
    done: for time in 0..<64 {
        r4:=transmute(V16)V4i(transmute(i32)[4]u8{rng[time*4],rng[time*4+1],rng[time*4+2],
            rng[time*4+3]})
        control:=simd.shuffle(r4,r4,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3)
        ep0:=wiggle4(cur0,control,0)
        ep1:=wiggle4(cur1,control,3)
        if data.has_any_alpha {
            t:=ep0
            ep0=simd.min(ep0,ep1)
            ep1=simd.max(t,ep1)
        }
        e0:=simd.to_array(ep0)
        e1:=simd.to_array(ep1)
        eps:[4]Endpoints
        for i in 0..<4 {eps[i]={Unpacked_565(e0[i]),Unpacked_565(e1[i])}}
        palettes:[4][4]Color
        common.bc1_palettes_batched(eps[:],palettes[:],mode)
        errs:[4]u32
        common.bc1_eval_palettes(&ctx,errs[:],palettes[:])
        v_err:=transmute(V4i)errs
        if simd.reduce_or(simd.lanes_gt(cur_best_err,v_err))!=0 {
            best_overall:=simd.reduce_min(simd.shl(v_err,V4u(2))|V4i{0,1,2,3})
            i:=best_overall&3
            best_err:=best_overall>>2
            err^=u32(best_err)
            cur_best_err=V4i(best_err)
            best=eps[i]
            if best_err==0 {break done}
        }
        accept:=simd.lanes_gt(thresh,v_err-cur_err)
        cur_err=simd.select(accept,v_err,cur_err)
        cur0=simd.select(accept,ep0,cur0)
        cur1=simd.select(accept,ep1,cur1)
        thresh-=V4i(THRESHOLD_STEP)
    }
    if err^!=initial_error {
        block.endpoints=common.bc1_make_endpoints(common.unpacked_565_pack(best[0]),
            common.unpacked_565_pack(best[1]))
        palette:[4]Color
        common.bc1_palette(block.endpoints,&palette,mode)
        block.indices=common.bc1_find_indices_palette(colors,&palette)
    }
}

// Least squares endpoints for fixed indices, in either mode.
Endpoint_LLS_Solver :: struct {
    aa,ab,bb:i32,
    ax,bx:[4]f32, // lanes B, G, R (A unused)
    fourc:bool,
    normalization_factor:f32,
}

@(private,rodata)
LLS_PRODUCTS := [2][4]u32{
    {2*2, (0*0)|((0*2)<<8)|((2*2)<<16), 1|(1<<8)|(1<<16), 0},
    {3*3, (3*3)<<16, (2*2)|((2*1)<<8)|((1*1)<<16), (1*1)|((1*2)<<8)|((2*2)<<16)},
}

@(private,rodata)
LLS_AB := [2][4][2]f32{
    {{2,0},{0,2},{1,1},{0,0}},
    {{3,0},{0,3},{2,1},{1,2}},
}

lls_solver_init :: proc "contextless" (s:^Endpoint_LLS_Solver,fourc:bool) {
    s^={fourc=fourc,normalization_factor=fourc?3.0:2.0}
}

lls_solver_accumulate :: proc "contextless" (s:^Endpoint_LLS_Solver,colors:^Color_Block,
    indices:u32) {
    w:=s.fourc?1:0
    t:=indices
    products:u32
    for i in 0..<16 {
        index:=t&3
        t>>=2
        products+=LLS_PRODUCTS[w][index]
        c:=colors[i]
        x:=[4]f32{f32(c[0]),f32(c[1]),f32(c[2]),f32(c[3])}
        wa:=LLS_AB[w][index][0]
        wb:=LLS_AB[w][index][1]
        s.ax+=wa*x
        s.bx+=wb*x
    }
    s.aa+=i32(products&0xff)
    s.ab+=i32((products>>8)&0xff)
    s.bb+=i32((products>>16)&0xff)
}

// False when the system has no unique solution.
lls_solver_solve :: proc "contextless" (s:^Endpoint_LLS_Solver) -> (a,b:u16,ok:bool) {
    det:=s.aa*s.bb-s.ab*s.ab
    if det==0 {return}
    inv_det:=s.normalization_factor/f32(det)
    vax:=Vec3f{s.ax[0],s.ax[1],s.ax[2]}
    vbx:=Vec3f{s.bx[0],s.bx[1],s.bx[2]}
    va:=(f32(s.bb)*inv_det)*vax+(f32(-s.ab)*inv_det)*vbx
    vb:=(f32(-s.ab)*inv_det)*vax+(f32(s.aa)*inv_det)*vbx
    return common.vec3f_to_quantized_565_rn(va),common.vec3f_to_quantized_565_rn(vb),true
}

optimize_endpoints_from_indices_raw :: proc "contextless" (endpoints:^u32,indices:u32,fourc:bool,
    colors:^Color_Block) -> bool {
    s:Endpoint_LLS_Solver
    lls_solver_init(&s,fourc)
    lls_solver_accumulate(&s,colors,indices)
    qa,qb,ok:=lls_solver_solve(&s)
    if !ok {return false}
    if (qa>qb)!=fourc {qa,qb=qb,qa}
    endpoints^=common.bc1_make_endpoints(qa,qb)
    return true
}

// Keeps the mode of the block, solves its endpoints for its indices, then reindexes.
optimize_endpoints_from_indices_inherit_reindex :: proc "contextless" (block:^BC1_Block,err:^u32,
    colors:^Color_Block,mode:Palette_Mode) -> bool {
    fourc:=common.bc1_is_4color(block.endpoints,mode)
    endpoints:=block.endpoints
    if !optimize_endpoints_from_indices_raw(&endpoints,block.indices,fourc,colors) {return false}
    if endpoints==block.endpoints {return false}
    palette:[4]Color
    common.bc1_palette(endpoints,&palette,mode)
    e:u32
    indices:=common.bc1_find_indices_palette(colors,&palette,&e)
    if e<err^ {
        err^=e
        block.endpoints=endpoints
        block.indices=indices
        return true
    }
    return false
}

optimize_endpoints_from_indices_inherit_no_reindex :: proc "contextless" (block:^BC1_Block,err:^u32,
    colors:^Color_Block,mode:Palette_Mode) -> bool {
    fourc:=common.bc1_is_4color(block.endpoints,mode)
    oldep:=block.endpoints
    endpoints:=oldep
    if !optimize_endpoints_from_indices_raw(&endpoints,block.indices,fourc,colors) {return false}
    if endpoints==oldep {return false}
    if mode==.Alpha {
        new_is_3c:=!common.bc1_is_4color(endpoints,mode)
        if fourc && common.bc1_one_bit_transparent_mask_from_indices(new_is_3c,
            block.indices)!=0 {return false}
    }
    nb:=BC1_Block{endpoints,block.indices}
    e:=common.bc1_compute_ssd_rgba(colors,nb,mode)
    if e<err^ {
        err^=e
        block^=nb
        return true
    }
    return false
}

optimize_endpoints_from_indices_iterative :: proc "contextless" (block:^BC1_Block,err:^u32,
    colors:^Color_Block,mode:Palette_Mode) {
    for {
        old:=block.indices
        if !optimize_endpoints_from_indices_inherit_reindex(block,err,colors,mode) {break}
        if old==block.indices {break}
    }
}

@(private)
u16_less :: proc(a,b:u16) -> bool {return a<b}

@(private)
try_all_pairs_heavy :: proc(block:^BC1_Block,err:^u32,colors:^Color_Block,
    mode:Palette_Mode) -> bool {
    uniques:[16]u16
    for i in 0..<16 {uniques[i]=common.quantize_565(colors[i])}
    common.stdsort(uniques[:],u16_less)
    count:=unique_u16(uniques[:])
    if count==1 {return false}
    ret:=false
    for i in 0..<count {
        for j in i+1..<count {
            trial:=BC1_Block{endpoints=common.bc1_make_endpoints(uniques[i],uniques[j])}
            palette:[4]Color
            e:u32
            common.bc1_palette(trial.endpoints,&palette,mode)
            trial.indices=common.bc1_find_indices_palette(colors,&palette,&e)
            optimize_endpoints_from_indices_iterative(&trial,&e,colors,mode)
            if e<err^ {
                ret=true
                err^=e
                block^=trial
            }
            if mode!=.Four_Color {
                trial.endpoints=(trial.endpoints>>16)|(trial.endpoints<<16)
                common.bc1_palette(trial.endpoints,&palette,mode)
                trial.indices=common.bc1_find_indices_palette(colors,&palette,&e)
                optimize_endpoints_from_indices_iterative(&trial,&e,colors,mode)
                if e<err^ {
                    ret=true
                    err^=e
                    block^=trial
                }
            }
        }
    }
    return ret
}

// The length of the sorted values without adjacent duplicates, compacted in place.
@(private)
unique_u16 :: proc "contextless" (v:[]u16) -> int {
    n:=len(v)
    it:=0
    for it<n-1 && v[it]!=v[it+1] {it+=1}
    if it>=n-1 {return n}
    out:=it
    it+=2
    for it<n {
        if v[out]!=v[it] {
            out+=1
            v[out]=v[it]
        }
        it+=1
    }
    return out+1
}

@(private)
compress_0 :: proc "contextless" (block:^BC1_Block,err:^u32,colors:^Color_Block,mode:Palette_Mode) {
    err^=INIT_ERROR
    data:Startup_Data
    if !startup(&data,block,err,colors,mode) {return}
    if !four_means(&data,block,err,colors,mode,{.Reduced_Candidates}) {return}
    optimize_endpoints_from_indices_inherit_reindex(block,err,colors,mode)
}

@(private)
compress_1 :: proc "contextless" (block:^BC1_Block,err:^u32,colors:^Color_Block,mode:Palette_Mode) {
    err^=INIT_ERROR
    data:Startup_Data
    if !startup(&data,block,err,colors,mode) {return}
    if !four_means(&data,block,err,colors,mode,{}) {return}
    optimize_endpoints_from_indices_iterative(block,err,colors,mode)
}

compress_level_2 :: proc "contextless" (block:^BC1_Block,err:^u32,colors:^Color_Block,
    mode:Palette_Mode) {
    err^=INIT_ERROR
    data:Startup_Data
    if !startup(&data,block,err,colors,mode) {return}
    if !four_means(&data,block,err,colors,mode,{}) {return}
    optimize_endpoints_from_indices_iterative(block,err,colors,mode)
    greedy_optimize(&data,block,err,colors,mode,false)
}

@(private)
compress_3 :: proc(block:^BC1_Block,err:^u32,colors:^Color_Block,mode:Palette_Mode,
    level:common.Level) {
    err^=INIT_ERROR
    data:Startup_Data
    if !startup(&data,block,err,colors,mode) {
        greedy_optimize(&data,block,err,colors,mode,true)
        return
    }
    if !four_means(&data,block,err,colors,mode,{.PCA}) {
        greedy_optimize(&data,block,err,colors,mode,true)
        return
    }
    optimize_endpoints_from_indices_iterative(block,err,colors,mode)
    if level>=.Reference {try_all_pairs_heavy(block,err,colors,mode)}
    if err^==0 {return}
    anneal(&data,block,err,colors,mode)
    greedy_optimize(&data,block,err,colors,mode,true)
}

// One block from canonical colors (BGRA): alpha 255, or with One_Bit_Alpha alpha 0 or 255
// with transparent texels all 0. bc3_color: the color half of BC3, always four colors.
compress_block :: proc(colors:^Color_Block,level:common.Level,options:common.Options,
    bc3_color:bool) -> BC1_Block {
    mode:Palette_Mode=.BC1_One_Bit_Alpha in options?.Alpha:.No_Alpha
    if bc3_color {mode=.Four_Color}
    err:u32=INIT_ERROR
    block:BC1_Block
    switch level {
    case .Very_Slow,.Reference: compress_3(&block,&err,colors,mode,level)
    case .Slow: compress_level_2(&block,&err,colors,mode)
    case .Fast: compress_1(&block,&err,colors,mode)
    case .Very_Fast: compress_0(&block,&err,colors,mode)
    }
    if mode==.Four_Color {common.bc1_bc3_canonicalize(&block)}
    return block
}

// Makes a BGRA block what the encoder takes: transparency canonical with One_Bit_Alpha
// (and not bc3_color), alpha 255 otherwise.
canonicalize_colors :: proc "contextless" (colors:^Color_Block,options:common.Options,
    bc3_color:bool) {
    if !bc3_color && .BC1_One_Bit_Alpha in options {
        for i in 0..<16 {common.make_one_bit_transparent_canonical(&colors[i])}
    } else {
        common.kill_alpha(colors)
    }
}

// The 8 bytes of block i go to to[i*stride+offset:]; from is BGRA. bc3_color encodes the
// color half of BC3 (stride 16, offset 8).
compress :: proc(to:[]u8,stride,offset:int,from:[]Color_Block,level:common.Level,
    options:common.Options,bc3_color:bool) -> common.Error {
    if stride<8 || offset<0 || offset+8>stride {return .Invalid}
    if len(from)>0 && len(to)<(len(from)-1)*stride+offset+8 {return .Invalid}
    for i in 0..<len(from) {
        colors:=from[i]
        canonicalize_colors(&colors,options,bc3_color)
        block:=compress_block(&colors,level,options,bc3_color)
        common.bc1_put_block(to[i*stride+offset:],block)
    }
    return .None
}
