package bc7

import "base:intrinsics"
import "core:simd"
import "mirai:asset"
import "mirai:cook/compressor/texture/bc67"

// The block encoder: candidate trials, ranking, refinement and bit packing.

// Color bbox of each subset of partition p; unused subsets are zero.
@(private)
partition_info_calc :: proc "contextless" (info:^Partition_Info,block:^[16]Color,p,ns:int) {
    B64 :: #simd[64]u8
    U16 :: #simd[16]u32
    im:=bc67.SECTION_TBL[ns&3][p&63]
    sub:=simd.shr(U16(im),U16{0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30})&U16(3)
    px:=intrinsics.unaligned_load((^B64)(block))
    info.bbox={}
    for s in 0..<min(ns,3) {
        sel:=simd.lanes_eq(sub,U16(u32(s)))
        if simd.reduce_or(sel)==0 {continue}
        m:=transmute(B64)sel
        lo:=px|~m
        hi:=px&m
        l32:=transmute([2]#simd[32]u8)lo; h32:=transmute([2]#simd[32]u8)hi
        l16:=transmute([2]V16b)simd.min(l32[0],l32[1])
        h16:=transmute([2]V16b)simd.max(h32[0],h32[1])
        l8:=transmute([2]#simd[8]u8)simd.min(l16[0],l16[1])
        h8:=transmute([2]#simd[8]u8)simd.max(h16[0],h16[1])
        l4:=transmute([2]#simd[4]u8)simd.min(l8[0],l8[1])
        h4:=transmute([2]#simd[4]u8)simd.max(h8[0],h8[1])
        lo4:=simd.min(l4[0],l4[1])
        hi4:=simd.max(h4[0],h4[1])
        info.bbox[s]=transmute([2]Color)simd.shuffle(lo4,hi4,0,1,2,3,4,5,6,7)
    }
}

@(private)
partition_all_same :: #force_inline proc "contextless" (info:^Partition_Info,s:int) -> bool {
    return info.bbox[s][0]==info.bbox[s][1]
}

MAX_RESULTS :: 64

@(private)
Result :: struct {
    heap_err:u64, // sort key, from make_heap_err
    slot:^Block_State,
}

// The current candidates: a max-heap on heap_err over a pool of states.
@(private)
Results :: struct {
    best_err:Error,
    heap_size:int, // capacity
    used:int,
    heap:[MAX_RESULTS]Result,
    pool:[MAX_RESULTS]Block_State,
    mpeb:^Mode_Err_Bias,
}

@(private)
results_init :: proc "contextless" (r:^Results,mpeb:^Mode_Err_Bias) {
    r.best_err=ERROR_MAX
    r.heap_size=MAX_RESULTS
    r.used=0
    r.mpeb=mpeb
    for i in 0..<MAX_RESULTS {
        r.heap[i].heap_err=u64(ERROR_MAX)
        r.heap[i].slot=&r.pool[i]
        r.pool[i].err=ERROR_MAX
    }
}

@(private)
make_heap_err :: proc "contextless" (r:^Results,st:^Block_State) -> u64 {
    err:=st.err
    if r.mpeb!=nil {err+=r.mpeb.ssd_err_bias[st.mode&7]}
    heap_err:=u64(err)<<9
    heap_err|=u64(7-st.mode)<<6
    heap_err|=u64(st.p)
    heap_err|=u64(st.subsets[0].isbit)<<2
    heap_err|=u64(st.subsets[0].rbit)
    return heap_err
}

@(private)
results_adjust_heap :: proc "contextless" (heap:[]Result,i:int,n:int) {
    i:=i
    for {
        child:=i*2+1
        if child>=n {break}
        if child+1<n && heap[child].heap_err<heap[child+1].heap_err {child+=1}
        if heap[child].heap_err<heap[i].heap_err {break}
        heap[i],heap[child]=heap[child],heap[i]
        i=child
    }
}

@(private)
results_make_heap :: proc "contextless" (heap:[]Result,n:int) {
    cur:=n>>1
    for cur>0 {
        cur-=1
        results_adjust_heap(heap,cur,n)
    }
}

@(private)
results_add_state :: proc "contextless" (r:^Results,st:^Block_State) {
    if st.err<r.best_err {r.best_err=st.err}
    heap_err:=make_heap_err(r,st)
    if r.used<r.heap_size {
        r.heap[r.used].heap_err=heap_err
        r.heap[r.used].slot^=st^
        r.used+=1
        if r.used==r.heap_size {results_make_heap(r.heap[:],r.used)}
        return
    }
    if r.heap_size<=0 || heap_err>=r.heap[0].heap_err {return}
    r.heap[0].heap_err=heap_err
    r.heap[0].slot^=st^
    results_adjust_heap(r.heap[:],0,r.used)
}

@(private)
results_shrink :: proc "contextless" (r:^Results,new_num:int) {
    if r.used<=new_num {
        r.heap_size=new_num
        return
    }
    for i in 0..<r.used {r.heap[i].heap_err=make_heap_err(r,r.heap[i].slot)}
    results_make_heap(r.heap[:],new_num)
    for i in new_num..<r.used {
        if r.heap[i].heap_err>=r.heap[0].heap_err {continue}
        r.heap[0],r.heap[i]=r.heap[i],r.heap[0]
        results_adjust_heap(r.heap[:],0,new_num)
    }
    r.heap_size=new_num
    r.used=new_num
}

@(private)
Optimal_Endpoints :: struct {
    error:Error,
    endpoints:[2]Color,
    ind:u8,
}

// Best endpoints and index for a constant color in the 2- and 3-subset modes.
@(private)
find_optimal_endpoints_for_constant_color :: proc "contextless" (mode:int,color:Color,
    alpha_enabled:bool,
    need_pbit_value:int) -> Optimal_Endpoints {
    MAX_CONSTANT_INDEX :: [5]int{3,3,1,1,1}
    NUM_PBIT_VALUES :: [5]int{4,2,1,4,4}
    max_constant_index:=MAX_CONSTANT_INDEX
    num_pbit_values:=NUM_PBIT_VALUES
    best:=Optimal_Endpoints{error=ERROR_MAX}
    mode:=mode==7 ? 4 : mode
    if mode<0 || mode>4 {return best}
    need:=need_pbit_value
    p0,p1:int
    if need==-1 {
        p0=0; p1=num_pbit_values[mode]-1
    } else {
        if mode==1 {need=need!=0 ? 1 : 0}
        p0=need; p1=need
    }
    base_table_id:=0
    for i in 0..<mode {base_table_id+=num_pbit_values[i]*max_constant_index[i]}
    for p in p0..=p1 {
        for i in 1..=max_constant_index[mode] {
            table_id:=base_table_id+p*max_constant_index[mode]+(i-1)
            if table_id<0 || table_id>=len(bc67.BC7_OPTIMAL_ENDPOINTS) {continue}
            ep:=&bc67.BC7_OPTIMAL_ENDPOINTS[table_id]
            error:Error
            for c in 0..<3 {error+=Error(ep[color[c]].err)}
            if alpha_enabled {error+=Error(ep[color[3]].err)}
            if error<best.error {
                best.error=error
                for c in 0..<4 {
                    best.endpoints[0][c]=ep[color[c]].lo
                    best.endpoints[1][c]=ep[color[c]].hi
                }
                best.ind=u8(i)
            }
        }
    }
    return best
}

// Initial trials of mode M with partition p (or the rbit/isbit config + 1 of
// modes 4 and 5); adds them to results.
@(private)
try_partition :: proc "contextless" (block:^[16]Color,prep:^Prep,results:^Results,opt:^Enc_Options,
    p_or_config:int,pca_subsets:[3]u8,$M:int) -> Error {
    NS :: MODE_NS[M]
    RB :: MODE_RB[M]
    ISB :: MODE_ISB[M]
    IB2 :: MODE_IB2[M]
    AB :: MODE_AB[M]
    CB :: MODE_CB[M]
    HAS_PBITS :: MODE_EPB[M]+MODE_SPB[M]!=0
    p:=IB2!=0 ? 0 : p_or_config
    config_override:=IB2!=0 ? p_or_config-1 : -1
    if p<0 || p>=64 {return ERROR_MAX}
    if results.best_err==0 || !opt.enable_mode[M] {return ERROR_MAX}
    best_err:=ERROR_MAX
    seed_info:Partition_Info
    when NS>1 {
        partition_info_calc(&seed_info,block,p,NS)
    } else {
        seed_info=prep.info_1sub
    }
    st:Block_State
    st.mode=u8(M)
    st.p=u8(p)
    num_rbit:=1<<uint(RB)
    num_isbit:=ISB+1
    override_rbit:=-1
    override_isbit:=-1
    if opt.flags&(SEPARATE_ALPHA|PRESERVE_EXTREMES)!=0 {num_rbit=1}
    if config_override>=0 {
        num_rbit=1; num_isbit=1
        override_rbit=config_override&3
        override_isbit=config_override&4!=0 ? 1 : 0
    } else if ISB!=0 && opt.flags&MODE4_ISB1_ONLY!=0 {
        num_isbit=1
        override_isbit=1
    }
    for rbit_iter in 0..<num_rbit {
        rbit:=override_rbit>=0 ? override_rbit : rbit_iter
        block_in:Block_Input
        block_input_init(&block_in,block,bc67.SUBSET_TO_INDS[NS-1][p],rbit)
        input:[NS]Subset_Input
        total_pixels:=0
        for s in 0..<NS {
            num:=int(bc67.NUM_PIXELS_PER_SUBSET[NS][p][s])
            subset_input_init(&input[s],raw_data(block_in.pixels[total_pixels:]),num,
                alpha_chan_index(rbit),
                opt.alpha_weight)
            total_pixels+=num
        }
        for isbit_iter in 0..<num_isbit {
            isbit:=u8(override_isbit>=0 ? override_isbit : isbit_iter)
            total_err:Error
            for s in 0..<NS {
                in_:=&input[s]
                sst:=&st.subsets[s]
                subset_init_empty(sst,isbit,0)
                sst.endpoints=(^[2]Color)(&seed_info.bbox[s])^
                subset_set_rbit(sst,rbit)
                sst.pca_subset=pca_subsets[s]+1
                if partition_all_same(&seed_info,s) {
                    need_pbit_value:=-1
                    if AB>0 && opt.flags&PRESERVE_EXTREMES!=0 {
                        need_pbit_value=opt.flags&PRESERVE_A0!=0 ? 0 : 3
                    }
                    enable_alpha:=AB>0 && opt.flags&IGNORE_ALPHA==0
                    opt_ep:=find_optimal_endpoints_for_constant_color(M,seed_info.bbox[s][0],
                        enable_alpha,
                        need_pbit_value)
                    sst.endpoints=opt_ep.endpoints
                    for i in 0..<in_.num_pixels {sst.idxs[0][i]=opt_ep.ind}
                    sst.err=Error(in_.num_pixels)*opt_ep.error
                    sst.scalar_err=0
                    if AB==0 && opt.flags&IGNORE_ALPHA==0 {
                        d:=int(seed_info.bbox[s][0][3])-255
                        sst.err+=Error(in_.num_pixels*d*d)
                    }
                    when !HAS_PBITS {
                        sst.pbits=0
                    } else {
                        PBIT_MASK :: u8(128>>uint(CB))
                        sst.pbits=(opt_ep.endpoints[0][0]&PBIT_MASK!=0 ? 1 : 0)|
                            (opt_ep.endpoints[1][0]&PBIT_MASK!=0 ? 2 : 0)
                    }
                    calc_endpoints_and_pbits(&sst.endpoints_q,sst,opt.flags,int(sst.pbits),M)
                } else {
                    if opt.flags&NO_INITIAL_BBOX==0 {trial(sst,in_,opt.flags,-1,M)}
                    reduced:=opt.flags&RETAIN_MASK
                    initial_pca(sst,in_,reduced,prep,M)
                    if opt.partition_lsq_iters!=0 {
                        refine_subset_lsq_endpoints_iterated(sst,in_,reduced,
                            opt.partition_lsq_iters,M)
                    }
                }
                total_err+=sst.err
            }
            st.err=total_err
            results_add_state(results,&st)
            best_err=min(best_err,st.err)
        }
    }
    return best_err
}

@(private)
try_partition_dispatch :: proc "contextless" (block:^[16]Color,prep:^Prep,results:^Results,
    opt:^Enc_Options,
    mode,p:int,pca_subsets:[3]u8) -> Error {
    switch mode {
    case 0: return try_partition(block,prep,results,opt,p,pca_subsets,0)
    case 1: return try_partition(block,prep,results,opt,p,pca_subsets,1)
    case 2: return try_partition(block,prep,results,opt,p,pca_subsets,2)
    case 3: return try_partition(block,prep,results,opt,p,pca_subsets,3)
    case 4: return try_partition(block,prep,results,opt,p,pca_subsets,4)
    case 5: return try_partition(block,prep,results,opt,p,pca_subsets,5)
    case 6: return try_partition(block,prep,results,opt,p,pca_subsets,6)
    case 7: return try_partition(block,prep,results,opt,p,pca_subsets,7)
    }
    return ERROR_MAX
}

@(private)
swap_pbits :: #force_inline proc "contextless" (x:u8) -> u8 {return ((x&2)>>1)|((x&1)<<1)}

@(private)
canonicalize_subset :: proc "contextless" (st:^Subset_State,anchor_pos:int,ib1_msb,ib2_msb:u8) {
    ep:=st.endpoints
    epq:=st.endpoints_q
    isbit:=int(st.isbit&1)
    vector_inds:=&st.idxs[isbit]
    scalar_inds:=&st.idxs[isbit~1]
    vector_msb:=isbit!=0 ? ib2_msb : ib1_msb
    scalar_msb:=isbit!=0 ? ib1_msb : ib2_msb
    if vector_inds[anchor_pos]&vector_msb!=0 {
        st.endpoints={ep[1],ep[0]}
        st.endpoints_q={epq[1],epq[0]}
        st.pbits=swap_pbits(st.pbits)
        t:=vector_msb*2-1
        for i in 0..<16 {vector_inds[i]~=t}
    }
    if ib2_msb!=0 {
        st.endpoints[0][3]=ep[0][3]; st.endpoints[1][3]=ep[1][3]
        st.endpoints_q[0][3]=epq[0][3]; st.endpoints_q[1][3]=epq[1][3]
        if scalar_inds[anchor_pos]&scalar_msb!=0 {
            st.endpoints[0][3]=ep[1][3]; st.endpoints[1][3]=ep[0][3]
            st.endpoints_q[0][3]=epq[1][3]; st.endpoints_q[1][3]=epq[0][3]
            t:=scalar_msb*2-1
            for i in 0..<16 {scalar_inds[i]~=t}
        }
    }
}

// Swaps endpoints so that the anchor index bits are zero.
@(private)
canonicalize :: proc "contextless" (st:^Block_State) {
    mode:=&bc67.BC7_MODES[st.mode&7]
    ib1_msb:=u8((1<<mode.ib)>>1)
    ib2_msb:=u8((1<<mode.ib2)>>1)
    anchors:=int(bc67.SUBSET_ANCHORS[mode.ns-1][st.p&63])<<4
    for s in 0..<int(mode.ns) {
        canonicalize_subset(&st.subsets[s],(anchors>>uint(s*4))&0xf,ib1_msb,ib2_msb)
    }
}

@(private)
remove_anchor_bit :: #force_inline proc "contextless" (idxs,anchor_bit:u64) -> u64 {
    lo:=anchor_bit-1
    return (idxs&lo)|((idxs>>1)&~lo)
}

@(private)
set_bits :: #force_inline proc "contextless" (base:^[2]u64,bit_idx,num_bits:int,in_val:u64) -> int {
    if num_bits==0 {return bit_idx}
    word:=(bit_idx>>6)&1
    res:=uint(bit_idx&63)
    val:=in_val&((u64(1)<<uint(num_bits))-1)
    base[word]|=val<<res
    if num_bits>64-int(res) {base[1]|=val>>(64-res)}
    return bit_idx+num_bits
}

@(private)
emit_bits :: proc "contextless" (out:^[16]u8,st:^Block_State,$M:int) {
    NS :: MODE_NS[M]
    IB :: MODE_IB[M]
    IB2 :: MODE_IB2[M]
    CB :: MODE_CB[M]
    AB :: MODE_AB[M]
    p:=int(st.p&63)
    isbit:=st.subsets[0].isbit
    rbit:=st.subsets[0].rbit
    idxs,idxs2:u64
    inds:=bc67.SUBSET_TO_INDS[NS-1][p]
    for s in 0..<NS {
        sst:=&st.subsets[s]
        num:=int(bc67.NUM_PIXELS_PER_SUBSET[NS][p][s])
        for j in 0..<num {
            i:=uint(inds&0xf)
            inds>>=4
            idxs|=u64(sst.idxs[0][j])<<(i*uint(IB))
            idxs2|=u64(sst.idxs[1][j])<<(i*uint(IB2))
        }
    }
    anchor1_bit,anchor2_bit:u64
    when NS>=2 {
        a1:=NS==2 ? asset.BC7_ANCHORS_2[p] : asset.BC7_ANCHORS_3[p][0]
        anchor1_bit=u64(1)<<uint(IB*(int(a1)+1)-1)
    }
    when NS>=3 {
        anchor2_bit=u64(1)<<uint(IB*(int(asset.BC7_ANCHORS_3[p][1])+1)-1)
    }
    idxs=remove_anchor_bit(idxs,max(anchor1_bit,anchor2_bit))
    idxs=remove_anchor_bit(idxs,min(anchor1_bit,anchor2_bit))
    idxs=remove_anchor_bit(idxs,(u64(1)<<uint(IB))>>1)
    idxs2=remove_anchor_bit(idxs2,(u64(1)<<uint(IB2))>>1)
    data:[2]u64
    pos:=0
    pos=set_bits(&data,pos,M+1,u64(1)<<uint(M))
    pos=set_bits(&data,pos,MODE_PB[M],u64(p))
    pos=set_bits(&data,pos,MODE_RB[M],u64(rbit))
    pos=set_bits(&data,pos,MODE_ISB[M],u64(isbit))
    for c in 0..<3 {
        for s in 0..<NS {
            for e in 0..<2 {pos=set_bits(&data,pos,CB,
                u64(st.subsets[s].endpoints_q[e][c]>>uint(8-CB)))}
        }
    }
    for s in 0..<NS {
        for e in 0..<2 {pos=set_bits(&data,pos,AB,
            u64(int(st.subsets[s].endpoints_q[e][3])>>uint(8-AB)))}
    }
    NUM_PBITS :: MODE_EPB[M]*2+MODE_SPB[M]
    for s in 0..<NS {pos=set_bits(&data,pos,NUM_PBITS,u64(st.subsets[s].pbits))}
    pos=set_bits(&data,pos,IB*16-NS,idxs)
    when IB2!=0 {pos=set_bits(&data,pos,IB2*16-NS,idxs2)}
    for i in 0..<8 {
        out[i]=u8(data[0]>>uint(i*8))
        out[8+i]=u8(data[1]>>uint(i*8))
    }
}

// Packs a canonicalized state into block bits.
@(private)
emit :: proc "contextless" (out:^[16]u8,st:^Block_State) {
    switch st.mode {
    case 0: emit_bits(out,st,0)
    case 1: emit_bits(out,st,1)
    case 2: emit_bits(out,st,2)
    case 3: emit_bits(out,st,3)
    case 4: emit_bits(out,st,4)
    case 5: emit_bits(out,st,5)
    case 6: emit_bits(out,st,6)
    case 7: emit_bits(out,st,7)
    }
}

// The mode-5 encoding of a solid color.
@(private)
encode_single_color_block :: proc "contextless" (out:^[16]u8,rgba:Color) {
    r:=u64(rgba[0]); g:=u64(rgba[1]); b:=u64(rgba[2]); a:=u64(rgba[3])
    BIT6_MASK :: u64((0x40<<8)|(0x40<<22)|(0x40<<36))
    LO7_MASK :: u64((0x7f<<8)|(0x7f<<22)|(0x7f<<36))
    color_bits:=(r<<8)|(g<<22)|(b<<36)
    t:=color_bits<<6
    color_bits=((color_bits>>1)&LO7_MASK)-(color_bits&~LO7_MASK)
    color_bits+=t+(t&BIT6_MASK)
    color_bits|=a<<50
    color_bits|=0x20
    hi:=u64(0xaaaaaaac)
    for i in 0..<8 {
        out[i]=u8(color_bits>>uint(i*8))
        out[8+i]=u8(hi>>uint(i*8))
    }
}

// Whether the block is a solid-color block as encode_single_color_block writes.
@(private)
is_encoded_single_color_block :: proc "contextless" (block:^[16]u8) -> bool {
    if block[0]!=0x20 {return false}
    all_inds:u64
    for i in 0..<8 {all_inds|=u64(block[8+i])<<uint(i*8)}
    return (all_inds&~u64(3))==0xaaaaaaac
}

@(private)
try_refine :: proc "contextless" (block:^[16]Color,r:^Results,opt:^Enc_Options,
    prep:^Prep) -> ^Block_State {
    full_flags:=opt.flags
    flags:=full_flags&~IDXS_EXACT
    if r.best_err>0 {
        if opt.narrow2!=0 {
            for i in 0..<r.used {
                slot:=r.heap[i].slot
                input:Input
                input_get_state(&input,block,slot,opt.alpha_weight)
                refine_lsq_endpoints_pass(&input,slot,flags,3)
                if slot.err==0 {return slot}
            }
            results_shrink(r,opt.narrow2)
        }
        for i in 0..<r.used {
            slot:=r.heap[i].slot
            refine(block,slot,flags,opt.optiters_early,opt,prep)
            if slot.err==0 {return slot}
        }
    }
    results_shrink(r,1)
    best:=r.heap[0].slot
    filtered:=full_flags
    filtered&=~ALL_PCA
    filtered|=BRUTE_PBITS
    refine(block,best,filtered,opt.optiters_late,opt,prep)
    return best
}

@(private)
Ranking_Heap :: struct {
    entries:[NBEST]u64,
    used:int,
    capacity:int,
}

@(private)
ranking_heap_add :: #force_inline proc "contextless" (h:^Ranking_Heap,overall_err,pca_err:f32,
    weights:[2]f32,mode,partition:u32) #no_bounds_check {
    total_err:=weights[0]*overall_err+weights[1]*pca_err
    clamped:=total_err>0 ? total_err : 0
    key:=(u64(transmute(u32)clamped)<<32)|u64(mode<<8)|u64(partition)
    if h.used<h.capacity {
        h.entries[h.used]=key
        h.used+=1
        i:=h.used-1
        for i>0 {
            parent:=(i-1)>>1
            if !(h.entries[parent]<h.entries[i]) {break}
            h.entries[parent],h.entries[i]=h.entries[i],h.entries[parent]
            i=parent
        }
    } else if h.capacity>0 && key<h.entries[0] {
        h.entries[0]=key
        i:=0
        n:=h.capacity
        for {
            child:=i*2+1
            if child>=n {break}
            if child+1<n && h.entries[child]<h.entries[child+1] {child+=1}
            if h.entries[child]<h.entries[i] {break}
            h.entries[i],h.entries[child]=h.entries[child],h.entries[i]
            i=child
        }
    }
}

@(private)
ranking_heap_drain :: proc "contextless" (h:^Ranking_Heap,into:^[NBEST]Partition_Choice,
    into_count:^int,
    subsets:[][4]u8) -> f32 {
    into_count^=h.used
    worst_err:=f32(1e+10)
    if h.used>0 {worst_err=transmute(f32)u32(h.entries[0]>>32)}
    for i in 0..<h.used {
        c:=&into[i]
        option_id:=int(h.entries[i]&0xff)
        c.mode=u8((h.entries[i]>>8)&0xff)
        if option_id<len(subsets) {
            c.partition=subsets[option_id][3]
            for s in 0..<3 {c.subsets[s]=subsets[option_id][s]}
        }
    }
    h.used=0
    return worst_err
}

@(rodata)
@(private)
RANK_ERR_WEIGHTS := [5][2]f32{
    {1.0411,-1.0340},
    {1.2560,-1.2481},
    {1.4990,-1.4800},
    {1.1367,-1.1044},
    {1.0960,-1.0551},
}

@(private)
ranking_compute :: proc "contextless" (prep:^Prep,opt:^Enc_Options) {
    coll:=(opt.subsets!=nil && opt.forced_mode==-1) ? opt.subsets : &bc67.BC7_SUBSETS_FULL
    rk:=&prep.ranking
    results:=&prep.analysis
    prep.analysis_initialized=true
    rk.pca_subset1={0,0,0}
    if prep.max_ns>=2 {
        analysis_compute(results,&prep.local_block,coll.masks,coll.rcp_count,0,
            coll.num_subsets_part2,
            prep.has_alpha)
        rk.pca_subset1[0]=u8(coll.num_subsets_part2)
        heap:Ranking_Heap
        heap.capacity=clamp(opt.nbest_part2,0,NBEST)
        overall_err:=&results.storage[.Overall_Err]
        pca_err:=&results.storage[.Pca_Err]
        for i in 0..<coll.num_part2 {
            s0:=int(coll.subsets[i][0]); s1:=int(coll.subsets[i][1])
            sum_overall:=overall_err[s0]+overall_err[s1]
            sum_pca:=pca_err[s0]+pca_err[s1]
            if !prep.has_alpha {
                if opt.enable_mode[1] {ranking_heap_add(&heap,sum_overall,sum_pca,
                    RANK_ERR_WEIGHTS[0],1,u32(i))}
                if opt.enable_mode[3] {ranking_heap_add(&heap,sum_overall,sum_pca,
                    RANK_ERR_WEIGHTS[1],3,u32(i))}
            } else {
                if opt.enable_mode[7] {ranking_heap_add(&heap,sum_overall,sum_pca,
                    RANK_ERR_WEIGHTS[2],7,u32(i))}
            }
        }
        worst_err:=ranking_heap_drain(&heap,&rk.best_part2,&rk.num_part2,coll.subsets)
        if prep.max_ns>=3 && (worst_err>=opt.err_threshold_for_subset3 || opt.forced_mode!=-1) {
            n2:=coll.num_subsets_part2
            n3:=coll.num_subsets_all-n2
            analysis_compute(results,&prep.local_block,coll.masks,coll.rcp_count,n2,n3,false)
            rk.pca_subset1[0]=u8(coll.num_subsets_all)
            heap.capacity=clamp(opt.nbest_part3,0,NBEST)
            subsets3:=coll.subsets[coll.num_part2:]
            for i in 0..<coll.num_part3 {
                sum_overall,sum_pca:f32
                for s in 0..<3 {
                    j:=int(subsets3[i][s])
                    sum_overall+=overall_err[j]
                    sum_pca+=pca_err[j]
                }
                if opt.enable_mode[0] && subsets3[i][3]<16 {
                    ranking_heap_add(&heap,sum_overall,sum_pca,RANK_ERR_WEIGHTS[3],0,u32(i))
                }
                if opt.enable_mode[2] {ranking_heap_add(&heap,sum_overall,sum_pca,
                    RANK_ERR_WEIGHTS[4],2,u32(i))}
            }
            ranking_heap_drain(&heap,&rk.best_part3,&rk.num_part3,subsets3)
        }
    }
    analysis_compute_1subset(results,&prep.local_block,int(rk.pca_subset1[0]))
}

// Analyses a block before encoding it; returns the block the encoder reads
// (A forced to 255 when alpha is ignored).
@(private)
prep_init :: proc "contextless" (prep:^Prep,in_block:^[16]Color,opt:^Enc_Options,
    force_consider_all_modes:bool) -> ^[16]Color {
    prep.local_block=in_block^
    prep.ranking.num_part2=0
    prep.ranking.num_part3=0
    prep.analysis_initialized=false
    block:=&prep.local_block
    prep.has_alpha=false
    if opt.flags&IGNORE_ALPHA!=0 {
        for i in 0..<16 {block[i][3]=255}
    } else {
        for i in 0..<16 {
            if block[i][3]!=255 {prep.has_alpha=true; break}
        }
    }
    prep.single_color=false
    {
        i:=1
        for i<16 && block[i]==block[0] {i+=1}
        if i==16 {prep.single_color=true}
    }
    if opt.flags&RANDOMIZED_MASK!=0 {
        vals:[8]u64
        for k in 0..<8 {
            v:u64
            for b in 0..<8 {
                t:=k*8+b
                v|=u64(block[t/4][t%4])<<uint(b*8)
            }
            vals[k]=v
        }
        prep.rand_seed=rand64_seed_from_u64s(vals[:])
    } else {
        prep.rand_seed=0
    }
    prep.max_ns=1
    if !prep.single_color {
        if (!prep.has_alpha || force_consider_all_modes) &&
            (opt.enable_mode[0] || opt.enable_mode[2]) {
            prep.max_ns=3
        } else if opt.enable_mode[1] || opt.enable_mode[3] || opt.enable_mode[7] {
            prep.max_ns=2
        }
    }
    if opt.forced_mode>=0 {prep.max_ns=3}
    ranking_compute(prep,opt)
    partition_info_calc(&prep.info_1sub,block,0,1)
    return block
}

@(private)
compute_effective_flags :: proc "contextless" (in_flags:Flags,prep:^Prep) -> Flags {
    flags:=in_flags
    if flags&PRESERVE_EXTREMES!=0 {
        nfo:=&prep.info_1sub
        if nfo.bbox[0][0][3]!=0 {flags&=~PRESERVE_A0}
        if nfo.bbox[0][1][3]!=255 {flags&=~PRESERVE_A255}
        if flags&PRESERVE_EXTREMES!=0 {
            if nfo.bbox[0][0][3]!=255 {flags|=DISABLE_MODE0123}
            if nfo.bbox[0][0][3]!=nfo.bbox[0][1][3] {flags|=DISABLE_MODE67}
        }
    }
    return flags
}

// Encodes a prepared block (BC7_CompressBlock_Sub); false if no mode applies.
@(private)
compress_block_sub :: proc "contextless" (out:^[16]u8,block:^[16]Color,in_opt:^Enc_Options,
    prep:^Prep,
    mpeb:^Mode_Err_Bias) -> bool {
    if prep.single_color {
        encode_single_color_block(out,block[0])
        return true
    }
    opt:=in_opt^
    if mpeb!=nil {
        for m in 0..<8 {
            if mpeb.ssd_err_bias[m]==max(u32) {opt.enable_mode[m]=false}
        }
    }
    opt.flags=compute_effective_flags(opt.flags,prep)
    if opt.flags&SEPARATE_ALPHA!=0 {
        nfo:=&prep.info_1sub
        alpha_diff:=int(nfo.bbox[0][1][3])-int(nfo.bbox[0][0][3])
        if alpha_diff>1 {opt.enable_mode[6]=false}
        opt.enable_mode[7]=false
    }
    if opt.flags&DISABLE_MODE0123!=0 {
        opt.enable_mode[0]=false; opt.enable_mode[1]=false
        opt.enable_mode[2]=false; opt.enable_mode[3]=false
    }
    if opt.flags&DISABLE_MODE67!=0 {
        opt.enable_mode[6]=false; opt.enable_mode[7]=false
    }
    ranking:=&prep.ranking
    results:Results=---
    results_init(&results,mpeb)
    results.heap_size=clamp(opt.narrow0,1,MAX_RESULTS)
    full_flags:=opt.flags
    opt.flags=opt.flags&~IDXS_EXACT
    if opt.forced_mode==-1 {
        try_partition(block,prep,&results,&opt,0,ranking.pca_subset1,6)
        try_partition(block,prep,&results,&opt,0,ranking.pca_subset1,5)
        try_partition(block,prep,&results,&opt,0,ranking.pca_subset1,4)
        for i in 0..<ranking.num_part2 {
            c:=&ranking.best_part2[i]
            try_partition_dispatch(block,prep,&results,&opt,int(c.mode),int(c.partition),c.subsets)
        }
        for i in 0..<ranking.num_part3 {
            c:=&ranking.best_part3[i]
            try_partition_dispatch(block,prep,&results,&opt,int(c.mode),int(c.partition),c.subsets)
        }
    } else {
        if opt.forced_mode<0 || opt.forced_mode>7 || opt.forced_partition<0 {return false}
        coll:=&bc67.BC7_SUBSETS_FULL
        subsets:=[3]u8{u8(coll.num_subsets_all),0,0}
        forced_partition:=opt.forced_partition
        switch bc67.BC7_MODES[opt.forced_mode].ns {
        case 1:
            if opt.forced_mode==4 || opt.forced_mode==5 {forced_partition+=1}
        case 2:
            for i in 0..<coll.num_part2 {
                if int(coll.subsets[i][3])==forced_partition {
                    subsets[0]=coll.subsets[i][0]; subsets[1]=coll.subsets[i][1]
                    break
                }
            }
        case 3:
            for i in coll.num_part2..<coll.num_part2+coll.num_part3 {
                if int(coll.subsets[i][3])==forced_partition {
                    subsets[0]=coll.subsets[i][0]; subsets[1]=coll.subsets[i][1]
                    subsets[2]=coll.subsets[i][2]
                    break
                }
            }
        }
        try_partition_dispatch(block,prep,&results,&opt,opt.forced_mode,forced_partition,subsets)
    }
    if results.used==0 {return false}
    opt.flags=full_flags
    best:=try_refine(block,&results,&opt,prep)
    canonicalize(best)
    emit(out,best)
    return true
}

// Encodes one RGBA block (BC7_CompressBlock).
compress_block :: proc "contextless" (out:^[16]u8,in_block:^[16]Color,opt:^Enc_Options,
    mpeb:^Mode_Err_Bias=nil) {
    prep:Prep=---
    block:=prep_init(&prep,in_block,opt,false)
    if !compress_block_sub(out,block,opt,&prep,mpeb) {out^={}}
}

// A state from block bits (the block must be valid).
@(private)
state_from_bits :: proc "contextless" (st:^Block_State,input:^[16]u8,flags:Flags) {
    desc:bc67.Block_Raw_Desc
    if !bc67.bc7_analyze_block_raw(&desc,input) {
        st^={}
        return
    }
    m:=desc.mode
    st.err=0
    st.mode=m.mode
    st.p=desc.partition_id
    pbit_mask:=(m.epb+m.spb)!=0 ? u8(128>>m.cb) : 0
    override_a:=m.ab==0 || flags&IGNORE_ALPHA!=0
    ns:=int(m.ns)
    inds:=bc67.SUBSET_TO_INDS[ns-1][st.p&63]
    for s in 0..<ns {
        sst:=&st.subsets[s]
        sst.err=0
        sst.scalar_err=0
        sst.isbit=desc.ind_sel
        sst.rbit=desc.rot
        num:=int(bc67.NUM_PIXELS_PER_SUBSET[ns][st.p&63][s])
        for c in 0..<4 {
            sst.endpoints[0][c]=desc.endpoints_raw[c][s*2+0]
            sst.endpoints[1][c]=desc.endpoints_raw[c][s*2+1]
        }
        sst.endpoints_q=sst.endpoints
        if override_a {
            c:=(int(desc.rot)-1)&3
            sst.endpoints_q[0][c]=255
            sst.endpoints_q[1][c]=255
        }
        sst.pbits=(sst.endpoints[0][0]&pbit_mask!=0 ? 1 : 0)|
            (sst.endpoints[1][0]&pbit_mask!=0 ? 2 : 0)
        for j in 0..<num {
            i:=int(inds&15)
            inds>>=4
            sst.idxs[0][j]=desc.inds[0][i]
            if m.ib2!=0 {sst.idxs[1][j]=desc.inds[1][i]}
        }
    }
}

@(private)
decode_state_mode :: proc "contextless" (st:^Block_State,block:^[16]Color,$M:int) {
    NS :: MODE_NS[M]
    p:=int(st.p&63)
    rbit:=int(st.subsets[0].rbit)
    _=rbit
    inds:=bc67.SUBSET_TO_INDS[NS-1][p]
    for s in 0..<NS {
        num:=int(bc67.NUM_PIXELS_PER_SUBSET[NS][p][s])
        pixels:[16]Color
        decode_subset(&pixels,&st.subsets[s],num,M)
        for j in 0..<num {
            block[inds&0xf]=pixels[j]
            inds>>=4
        }
    }
    when MODE_RB[M]!=0 {
        if rbit!=0 {
            for i in 0..<16 {block[i][3],block[i][rbit-1]=block[i][rbit-1],block[i][3]}
        }
    }
}

// Decodes a state to RGBA texels.
@(private)
decode_state :: proc "contextless" (st:^Block_State,block:^[16]Color) {
    switch st.mode {
    case 0: decode_state_mode(st,block,0)
    case 1: decode_state_mode(st,block,1)
    case 2: decode_state_mode(st,block,2)
    case 3: decode_state_mode(st,block,3)
    case 4: decode_state_mode(st,block,4)
    case 5: decode_state_mode(st,block,5)
    case 6: decode_state_mode(st,block,6)
    case 7: decode_state_mode(st,block,7)
    }
}

@(private)
reindex_block_mode :: proc "contextless" (st,src:^Block_State,input:[^]Subset_Input,flags:Flags,
    $M:int) -> int {
    NS :: MODE_NS[M]
    anchors:=NS>1 ? int(bc67.SUBSET_ANCHORS[NS-1][src.p&63])<<4 : 0
    reindex_err:Error
    for s in 0..<NS {
        sst:=&st.subsets[s]
        sst^=src.subsets[s]
        calc_indexes(sst,&input[s],flags,M)
        force_anchor_bit_zero(sst,&input[s],(anchors>>uint(s*4))&0xf,M)
        reindex_err+=sst.err
    }
    st.err=reindex_err
    st.mode=src.mode
    st.p=src.p
    return TOTAL_BITS_INDICES[M]
}

// New indices for src's endpoints; returns the bits that changed.
@(private)
reindex_block :: proc "contextless" (st,src:^Block_State,input:[^]Subset_Input,flags:Flags) -> int {
    switch src.mode {
    case 0: return reindex_block_mode(st,src,input,flags,0)
    case 1: return reindex_block_mode(st,src,input,flags,1)
    case 2: return reindex_block_mode(st,src,input,flags,2)
    case 3: return reindex_block_mode(st,src,input,flags,3)
    case 4: return reindex_block_mode(st,src,input,flags,4)
    case 5: return reindex_block_mode(st,src,input,flags,5)
    case 6: return reindex_block_mode(st,src,input,flags,6)
    case 7: return reindex_block_mode(st,src,input,flags,7)
    }
    return 0
}

@(private)
find_endpoints_mode :: proc "contextless" (st,src:^Block_State,input:^Input,flags:Flags,
    change_pbits,
    slow_anneal:bool,cache:^Endpoint_Coeff_Cache,$M:int) -> int {
    NS :: MODE_NS[M]
    IB :: MODE_IB[M]
    IB2 :: MODE_IB2[M]
    ISB :: MODE_ISB[M]
    st.mode=src.mode
    st.p=src.p
    st.err=0
    when IB2!=0 {
        sst:=&st.subsets[0]
        in_:=&input.subsets[0]
        sst^=src.subsets[0]
        ib:=(ISB!=0 && sst.isbit!=0) ? IB2 : IB
        ib2:=(ISB!=0 && sst.isbit!=0) ? IB : IB2
        refine_lsq_endpoints_core(sst,in_,ib,ib2,true,cache!=nil ? raw_data(cache.entry[:]) : nil)
        update_subset_error(sst,in_,flags,change_pbits ? -1 : int(sst.pbits),M)
        st.err=sst.err
    } else {
        for s in 0..<NS {
            sst:=&st.subsets[s]
            in_:=&input.subsets[s]
            sst^=src.subsets[s]
            refine_lsq_endpoints_core(sst,in_,IB,IB2,false,
                cache!=nil ? raw_data(cache.entry[s:]) : nil)
            update_subset_error(sst,in_,flags,change_pbits ? -1 : int(sst.pbits),M)
            st.err+=sst.err
        }
    }
    if slow_anneal {refine_anneal_subset(input,st,flags,-1,0,true,M)}
    bits:=TOTAL_BITS_ENDPOINTS[M]
    if change_pbits {bits+=TOTAL_BITS_PBITS[M]}
    return bits
}

// New endpoints for src's mode, partition and indices; returns the bits that
// changed.
@(private)
find_endpoints :: proc "contextless" (st,src:^Block_State,input:^Input,flags:Flags,change_pbits,
    slow_anneal:bool,cache:^Endpoint_Coeff_Cache=nil) -> int {
    switch src.mode {
    case 0: return find_endpoints_mode(st,src,input,flags,change_pbits,slow_anneal,cache,0)
    case 1: return find_endpoints_mode(st,src,input,flags,change_pbits,slow_anneal,cache,1)
    case 2: return find_endpoints_mode(st,src,input,flags,change_pbits,slow_anneal,cache,2)
    case 3: return find_endpoints_mode(st,src,input,flags,change_pbits,slow_anneal,cache,3)
    case 4: return find_endpoints_mode(st,src,input,flags,change_pbits,slow_anneal,cache,4)
    case 5: return find_endpoints_mode(st,src,input,flags,change_pbits,slow_anneal,cache,5)
    case 6: return find_endpoints_mode(st,src,input,flags,change_pbits,slow_anneal,cache,6)
    case 7: return find_endpoints_mode(st,src,input,flags,change_pbits,slow_anneal,cache,7)
    }
    return 0
}

@(private)
find_endpoints_init_cache :: proc "contextless" (cache:^Endpoint_Coeff_Cache,st:^Block_State,
    input:^Input) {
    mode:=&bc67.BC7_MODES[st.mode&7]
    ib:=int(mode.ib)
    ib2:=int(mode.ib2)
    if mode.isb!=0 && st.subsets[0].isbit!=0 {ib,ib2=ib2,ib}
    if mode.ib2!=0 {
        init_lsq_endpoints_cache(raw_data(cache.entry[:]),&st.subsets[0],&input.subsets[0],ib,ib2)
    } else {
        for s in 0..<int(mode.ns) {
            init_lsq_endpoints_cache(raw_data(cache.entry[s:]),&st.subsets[s],&input.subsets[s],ib,
                0)
        }
    }
}

// Accumulates, per texel, the error of every index of the IB-bit set; NC
// channels (3: RGB, 4: RGBA) against endpoints (not endpoints_q).
@(private)
accumulate_vector_errs :: proc "contextless" (errs:^Index_Errors,st:^Block_State,in_:^Input,
    $M:int) {
    NS :: MODE_NS[M]
    IB :: MODE_IB[M]
    IB2 :: MODE_IB2[M]
    ISB :: MODE_ISB[M]
    p:=int(st.p&63)
    inds:=bc67.SUBSET_TO_INDS[NS-1][p]
    ib:=(ISB!=0 && st.subsets[0].isbit!=0) ? IB2 : IB
    num_lerp:=1<<uint(ib)
    NC :: 4-min(IB2,1)
    for s in 0..<NS {
        sst:=&st.subsets[s]
        isb:=int(sst.isbit)
        ibs:=(ISB!=0 && isb!=0) ? IB2 : IB
        cols:[16][4]i32
        for j in 0..<1<<uint(ibs) {
            w:=lerp_factor(ibs,j)
            for c in 0..<3 {cols[j][c]=i32(sat_u8(i32(lerp_u8(sst.endpoints[0][c],
                sst.endpoints[1][c],w))))}
            when IB2==0 {
                cols[j][3]=i32(sat_u8(i32(lerp_u8(sst.endpoints[0][3],sst.endpoints[1][3],w))))
            }
        }
        for i in 0..<in_.subsets[s].num_pixels {
            px:=in_.subsets[s].pixels[i]
            cur:=&errs.err[inds&0xf]
            inds>>=4
            for j in 0..<num_lerp {
                e:i32
                for c in 0..<NC {
                    d:=i32(px[c])-cols[j][c]
                    e+=d*d
                }
                cur[j]+=Error(e)
            }
        }
    }
}

@(private)
accumulate_scalar_errs :: proc "contextless" (errs:^Index_Errors,st:^Block_State,in_:^Input,
    $M:int) {
    NS :: MODE_NS[M]
    IB :: MODE_IB[M]
    IB2 :: MODE_IB2[M]
    ISB :: MODE_ISB[M]
    p:=int(st.p&63)
    inds:=bc67.SUBSET_TO_INDS[NS-1][p]
    ib:=(ISB!=0 && st.subsets[0].isbit!=0) ? IB : IB2
    num_lerp:=1<<uint(ib)
    for s in 0..<NS {
        sst:=&st.subsets[s]
        ibs:=(ISB!=0 && sst.isbit!=0) ? IB : IB2
        cols:[16]int
        for j in 0..<1<<uint(ibs) {cols[j]=lerp_u8(sst.endpoints[0][3],sst.endpoints[1][3],
            lerp_factor(ibs,j))}
        for i in 0..<in_.subsets[s].num_pixels {
            a:=int(in_.subsets[s].pixels[i][3])
            cur:=&errs.err[inds&0xf]
            inds>>=4
            for j in 0..<num_lerp {
                d:=a-cols[j]
                cur[j]+=Error(d*d)
            }
        }
    }
}

// Adds the errors of every index choice at every texel (errs[0] for idxs[0],
// errs[1] for idxs[1]); the endpoints must be representable in the mode.
@(private)
accumulate_index_errors :: proc "contextless" (errs:^[2]Index_Errors,st:^Block_State,input:^Input) {
    switch st.mode {
    case 0: accumulate_vector_errs(&errs[0],st,input,0)
    case 1: accumulate_vector_errs(&errs[0],st,input,1)
    case 2: accumulate_vector_errs(&errs[0],st,input,2)
    case 3: accumulate_vector_errs(&errs[0],st,input,3)
    case 4:
        accumulate_vector_errs(&errs[st.subsets[0].isbit&1],st,input,4)
        accumulate_scalar_errs(&errs[(st.subsets[0].isbit&1)~1],st,input,4)
    case 5:
        accumulate_vector_errs(&errs[0],st,input,5)
        accumulate_scalar_errs(&errs[1],st,input,5)
        // The encoder falls through into mode 6 here.
        accumulate_vector_errs(&errs[0],st,input,6)
    case 6: accumulate_vector_errs(&errs[0],st,input,6)
    case 7: accumulate_vector_errs(&errs[0],st,input,7)
    }
}

@(private)
pick_indices :: proc "contextless" (st:^Block_State,iset:int,errs:^Index_Errors,$NS:int,$IB:int) {
    p:=int(st.p&63)
    NUM_LERP :: 1<<uint(IB)
    inds:=bc67.SUBSET_TO_INDS[NS-1][p]
    anchors:=int(bc67.SUBSET_ANCHORS[NS-1][p])<<4
    for s in 0..<NS {
        out:=&st.subsets[s].idxs[iset]
        num:=int(bc67.NUM_PIXELS_PER_SUBSET[NS][p][s])
        anchor:=(anchors>>uint(s*4))&0xf
        for i in 0..<num {
            cur:=&errs.err[inds&0xf]
            inds>>=4
            limit:=NUM_LERP>>(i==anchor ? 1 : 0)
            best:=0
            best_e:=cur[0]
            for j in 1..<limit {
                if cur[j]<best_e {best_e=cur[j]; best=j}
            }
            out[i]=u8(best)
        }
    }
}

// Picks the legal indices of least accumulated error.
@(private)
reindex_for_min_error :: proc "contextless" (st:^Block_State,errs:^[2]Index_Errors) {
    switch st.mode {
    case 0: pick_indices(st,0,&errs[0],3,3)
    case 1: pick_indices(st,0,&errs[0],2,3)
    case 2: pick_indices(st,0,&errs[0],3,2)
    case 3: pick_indices(st,0,&errs[0],2,2)
    case 4: pick_indices(st,0,&errs[0],1,2); pick_indices(st,1,&errs[1],1,3)
    case 5: pick_indices(st,0,&errs[0],1,2); pick_indices(st,1,&errs[1],1,2)
    case 6: pick_indices(st,0,&errs[0],1,4)
    case 7: pick_indices(st,0,&errs[0],2,2)
    }
}
