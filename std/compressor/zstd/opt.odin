package zstd

import "base:intrinsics"

@(private="file") LITFREQ_ADD :: 2
@(private="file") MAX_PRICE :: 1<<30
@(private="file") PREDEF_THRESHOLD :: 8
@(private="file") BITCOST_ACCURACY :: 8
@(private="file") BITCOST_MULTIPLIER :: 1<<BITCOST_ACCURACY

@(private="file")
to_u32 :: #force_inline proc "contextless" (b:bool) -> u32 {return b ? 1 : 0}

@(private="file")
bit_weight :: #force_inline proc "contextless" (stat:u32) -> u32 {
    return highbit32(stat+1)*BITCOST_MULTIPLIER
}

@(private="file")
frac_weight :: #force_inline proc "contextless" (raw_stat:u32) -> u32 {
    stat:=raw_stat+1
    hb:=highbit32(stat)
    b_weight:=hb*BITCOST_MULTIPLIER
    f_weight:=(stat<<BITCOST_ACCURACY)>>hb
    return b_weight+f_weight
}

@(private="file")
weight :: #force_inline proc "contextless" (stat:u32,opt_level:int) -> u32 {
    return opt_level!=0 ? frac_weight(stat) : bit_weight(stat)
}

@(private="file")
compressed_literals :: #force_inline proc "contextless" (opt_state:^Opt_State) -> bool {
    return opt_state.literal_compression_mode!=.Disable
}

@(private="file")
set_base_prices :: proc "contextless" (opt_state:^Opt_State,opt_level:int) {
    if compressed_literals(opt_state) {opt_state.lit_sum_base_price=weight(opt_state.lit_sum,opt_level)}
    opt_state.lit_length_sum_base_price=weight(opt_state.lit_length_sum,opt_level)
    opt_state.match_length_sum_base_price=weight(opt_state.match_length_sum,opt_level)
    opt_state.off_code_sum_base_price=weight(opt_state.off_code_sum,opt_level)
}

@(private="file")
sum_u32 :: proc "contextless" (table:[^]u32,nb_elts:int) -> u32 {
    total:u32=0
    for n:=0;n<nb_elts;n+=1 {total+=table[n]}
    return total
}

@(private="file") Base_Directive :: enum {Base_0_Possible,Base_1_Guaranteed}

@(private="file")
downscale_stats :: proc "contextless" (table:[^]u32,last_elt_index,shift:u32,base1:Base_Directive) -> u32 {
    sum:u32=0
    for s:u32=0;s<last_elt_index+1;s+=1 {
        base:u32=base1==.Base_1_Guaranteed ? 1 : to_u32(table[s]>0)
        new_stat:=base+(table[s]>>shift)
        sum+=new_stat
        table[s]=new_stat
    }
    return sum
}

@(private="file")
scale_stats :: proc "contextless" (table:[^]u32,last_elt_index,log_target:u32) -> u32 {
    prevsum:=sum_u32(table,int(last_elt_index)+1)
    factor:=prevsum>>log_target
    if factor<=1 {return prevsum}
    return downscale_stats(table,last_elt_index,highbit32(factor),.Base_1_Guaranteed)
}

@(rodata,private="file") Base_LL_Freqs:=[MAX_LL+1]u32{
    4,2,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,
    1,1,1,1,
}

@(rodata,private="file") Base_OFC_Freqs:=[MAX_OFF+1]u32{
    6,2,1,1,2,3,4,4,
    4,3,2,1,1,1,1,1,
    1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1,
}

// A first block starts from the literals of src and from fixed sequence statistics, any other
// from the statistics of the block before, scaled down.
@(private="file")
rescale_freqs :: proc "contextless" (opt_state:^Opt_State,src:[^]u8,src_size:int,opt_level:int) #no_bounds_check {
    literals_compressed:=compressed_literals(opt_state)
    opt_state.price_type=.Dynamic

    if opt_state.lit_length_sum==0 {
        if src_size<=PREDEF_THRESHOLD {opt_state.price_type=.Predef}

        if literals_compressed {
            intrinsics.mem_zero(opt_state.lit_freq,(MAX_LIT+1)*size_of(u32))
            hist_add(opt_state.lit_freq,src,src_size)
            opt_state.lit_sum=downscale_stats(opt_state.lit_freq,MAX_LIT,8,.Base_0_Possible)
        }

        lit_length_sum:u32=0
        for ll:=0;ll<=MAX_LL;ll+=1 {
            opt_state.lit_length_freq[ll]=Base_LL_Freqs[ll]
            lit_length_sum+=Base_LL_Freqs[ll]
        }
        opt_state.lit_length_sum=lit_length_sum

        for ml:=0;ml<=MAX_ML;ml+=1 {opt_state.match_length_freq[ml]=1}
        opt_state.match_length_sum=MAX_ML+1

        off_code_sum:u32=0
        for of:=0;of<=MAX_OFF;of+=1 {
            opt_state.off_code_freq[of]=Base_OFC_Freqs[of]
            off_code_sum+=Base_OFC_Freqs[of]
        }
        opt_state.off_code_sum=off_code_sum
    } else {
        if literals_compressed {opt_state.lit_sum=scale_stats(opt_state.lit_freq,MAX_LIT,12)}
        opt_state.lit_length_sum=scale_stats(opt_state.lit_length_freq,MAX_LL,11)
        opt_state.match_length_sum=scale_stats(opt_state.match_length_freq,MAX_ML,11)
        opt_state.off_code_sum=scale_stats(opt_state.off_code_freq,MAX_OFF,11)
    }

    set_base_prices(opt_state,opt_level)
}

@(private="file")
raw_literals_cost :: proc "contextless" (literals:[^]u8,lit_length:u32,opt_state:^Opt_State,opt_level:int) -> u32 {
    if lit_length==0 {return 0}

    if !compressed_literals(opt_state) {return (lit_length<<3)*BITCOST_MULTIPLIER}

    if opt_state.price_type==.Predef {return (lit_length*6)*BITCOST_MULTIPLIER}

    price:=opt_state.lit_sum_base_price*lit_length
    lit_price_max:=opt_state.lit_sum_base_price-BITCOST_MULTIPLIER
    for u:u32=0;u<lit_length;u+=1 {
        lit_price:=weight(opt_state.lit_freq[literals[u]],opt_level)
        if lit_price>lit_price_max {lit_price=lit_price_max}
        price-=lit_price
    }
    return price
}

@(private="file")
lit_length_price :: proc "contextless" (lit_length:u32,opt_state:^Opt_State,opt_level:int) -> u32 #no_bounds_check {
    if opt_state.price_type==.Predef {return weight(lit_length,opt_level)}

    if lit_length==BLOCK_SIZE_MAX {return BITCOST_MULTIPLIER+lit_length_price(BLOCK_SIZE_MAX-1,opt_state,opt_level)}

    code:=ll_code(lit_length)
    return (u32(LL_bits[code])*BITCOST_MULTIPLIER)+opt_state.lit_length_sum_base_price-weight(opt_state.lit_length_freq[code],opt_level)
}

@(private="file")
get_match_price :: #force_inline proc "contextless" (off_base,match_length:u32,opt_state:^Opt_State,opt_level:int) -> u32 #no_bounds_check {
    off_code:=highbit32(off_base)
    ml_base:=match_length-MINMATCH

    if opt_state.price_type==.Predef {return weight(ml_base,opt_level)+((16+off_code)*BITCOST_MULTIPLIER)}

    price:=(off_code*BITCOST_MULTIPLIER)+(opt_state.off_code_sum_base_price-weight(opt_state.off_code_freq[off_code],opt_level))
    if opt_level<2 && off_code>=20 {price+=(off_code-19)*2*BITCOST_MULTIPLIER}

    code:=ml_code(ml_base)
    price+=(u32(ML_bits[code])*BITCOST_MULTIPLIER)+(opt_state.match_length_sum_base_price-weight(opt_state.match_length_freq[code],opt_level))

    price+=BITCOST_MULTIPLIER/5

    return price
}

@(private="file")
update_stats :: proc "contextless" (opt_state:^Opt_State,lit_length:u32,literals:[^]u8,off_base,match_length:u32) {
    if compressed_literals(opt_state) {
        for u:u32=0;u<lit_length;u+=1 {opt_state.lit_freq[literals[u]]+=LITFREQ_ADD}
        opt_state.lit_sum+=lit_length*LITFREQ_ADD
    }

    {
        code:=ll_code(lit_length)
        opt_state.lit_length_freq[code]+=1
        opt_state.lit_length_sum+=1
    }

    {
        off_code:=highbit32(off_base)
        opt_state.off_code_freq[off_code]+=1
        opt_state.off_code_sum+=1
    }

    {
        ml_base:=match_length-MINMATCH
        code:=ml_code(ml_base)
        opt_state.match_length_freq[code]+=1
        opt_state.match_length_sum+=1
    }
}

// Only good for comparing.
@(private="file")
read_min_match :: #force_inline proc "contextless" (p:[^]u8,length:u32) -> u32 {
    return length==3 ? read32(p)<<8 : read32(p)
}

@(private="file")
insert_and_find_first_index_hash3 :: proc "contextless" (ms:^Match_State,next_to_update3:^u32,ip:[^]u8) -> u32 {
    hash_table3:=ms.hash_table3
    hash_log3:=ms.hash_log3
    base:=ms.window.base
    idx:=next_to_update3^
    target:=u32(pdiff(ip,base))
    hash_at_ip:=hash3_ptr(ip,hash_log3)

    for idx<target {
        hash_table3[hash3_ptr(padd(base,int(idx)),hash_log3)]=idx
        idx+=1
    }

    next_to_update3^=target
    return hash_table3[hash_at_ip]
}

// Adds a position to the tree and returns how many positions it covers.
@(private="file")
insert_bt1 :: #force_inline proc "contextless" (ms:^Match_State,ip,iend:[^]u8,target,mls:u32) -> u32 {
    c_params:=&ms.c_params
    hash_table:=ms.hash_table
    hash_log:=c_params.hash_log
    h:=hash_ptr(ip,hash_log,mls)
    bt:=ms.chain_table
    bt_log:=c_params.chain_log-1
    bt_mask:=(u32(1)<<bt_log)-1
    match_index:=hash_table[h]
    common_length_smaller,common_length_larger:int=0,0
    base:=ms.window.base
    match:[^]u8
    curr:=u32(pdiff(ip,base))
    bt_low:=bt_mask>=curr ? 0 : curr-bt_mask
    smaller_ptr:=&bt[2*(curr&bt_mask)]
    larger_ptr:=&bt[2*(curr&bt_mask)+1]
    dummy32:u32
    // Based on target: only what is still in the window once the update ends counts.
    window_low:=get_lowest_match_index(ms,target,c_params.window_log)
    match_end_idx:=curr+8+1
    best_length:=8
    nb_compares:=u32(1)<<c_params.search_log

    hash_table[h]=curr

    for ;nb_compares!=0 && match_index>=window_low;nb_compares-=1 {
        next_ptr:=([^]u32)(&bt[2*(match_index&bt_mask)])
        match_length:=min(common_length_smaller,common_length_larger)

        match=padd(base,int(match_index))
        match_length+=count(padd(ip,match_length),padd(match,match_length),iend)

        if match_length>best_length {
            best_length=match_length
            if match_length>int(match_end_idx-match_index) {
                match_end_idx=match_index+u32(match_length)
            }
        }

        // Equal up to the end: which side it goes is unknown, and a wrong side corrupts the tree.
        if uintptr(padd(ip,match_length))==uintptr(iend) {break}

        if match[match_length]<ip[match_length] {
            smaller_ptr^=match_index
            common_length_smaller=match_length
            if match_index<=bt_low {smaller_ptr=&dummy32;break}
            smaller_ptr=&next_ptr[1]
            match_index=next_ptr[1]
        } else {
            larger_ptr^=match_index
            common_length_larger=match_length
            if match_index<=bt_low {larger_ptr=&dummy32;break}
            larger_ptr=&next_ptr[0]
            match_index=next_ptr[0]
        }
    }

    smaller_ptr^=0
    larger_ptr^=0
    positions:u32=0
    if best_length>384 {positions=min(192,u32(best_length-384))}
    return max(positions,match_end_idx-(curr+8))
}

@(private="file")
update_tree_internal :: #force_inline proc "contextless" (ms:^Match_State,ip,iend:[^]u8,mls:u32) {
    base:=ms.window.base
    target:=u32(pdiff(ip,base))
    idx:=ms.next_to_update

    for idx<target {
        forward:=insert_bt1(ms,padd(base,int(idx)),iend,target,mls)
        idx+=forward
    }
    ms.next_to_update=target
}

update_tree :: proc "contextless" (ms:^Match_State,ip,iend:[^]u8) {
    update_tree_internal(ms,ip,iend,ms.c_params.min_match)
}

@(private="file")
insert_bt_and_get_all_matches :: #force_inline proc "contextless" (matches:[^]Match,ms:^Match_State,next_to_update3:^u32,ip,i_limit:[^]u8,rep:^[REP_NUM]u32,ll0,length_to_beat,mls:u32) -> u32 #no_bounds_check {
    c_params:=&ms.c_params
    sufficient_len:=min(c_params.target_length,OPT_NUM-1)
    base:=ms.window.base
    curr:=u32(pdiff(ip,base))
    hash_log:=c_params.hash_log
    min_match:u32=mls==3 ? 3 : 4
    hash_table:=ms.hash_table
    h:=hash_ptr(ip,hash_log,mls)
    match_index:=hash_table[h]
    bt:=ms.chain_table
    bt_log:=c_params.chain_log-1
    bt_mask:=(u32(1)<<bt_log)-1
    common_length_smaller,common_length_larger:int=0,0
    dict_limit:=ms.window.dict_limit
    bt_low:=bt_mask>=curr ? 0 : curr-bt_mask
    window_low:=get_lowest_match_index(ms,curr,c_params.window_log)
    match_low:=window_low!=0 ? window_low : 1
    smaller_ptr:=&bt[2*(curr&bt_mask)]
    larger_ptr:=&bt[2*(curr&bt_mask)+1]
    match_end_idx:=curr+8+1
    dummy32:u32
    mnum:u32=0
    nb_compares:=u32(1)<<c_params.search_log

    best_length:=int(length_to_beat-1)

    {
        last_r:=REP_NUM+ll0
        for rep_code:=ll0;rep_code<last_r;rep_code+=1 {
            rep_offset:=rep_code==REP_NUM ? rep[0]-1 : rep[rep_code]
            rep_index:=curr-rep_offset
            rep_len:u32=0
            // The wrap of rep_offset-1 discards the offsets 0 and -1.
            if rep_offset-1<curr-dict_limit {
                if rep_index>=window_low && read_min_match(ip,min_match)==read_min_match(padd(ip,-int(rep_offset)),min_match) {
                    rep_len=u32(count(padd(ip,int(min_match)),padd(ip,int(min_match)-int(rep_offset)),i_limit))+min_match
                }
            }
            if int(rep_len)>best_length {
                best_length=int(rep_len)
                matches[mnum].off=repcode_to_offbase(rep_code-ll0+1)
                matches[mnum].len=rep_len
                mnum+=1
                if rep_len>sufficient_len || uintptr(padd(ip,int(rep_len)))==uintptr(i_limit) {
                    return mnum
                }
            }
        }
    }

    if mls==3 && best_length<int(mls) {
        match_index3:=insert_and_find_first_index_hash3(ms,next_to_update3,ip)
        if match_index3>=match_low && curr-match_index3<(1<<18) {
            mlen:=count(ip,padd(base,int(match_index3)),i_limit)

            if mlen>=int(mls) {
                best_length=mlen
                matches[0].off=offset_to_offbase(curr-match_index3)
                matches[0].len=u32(mlen)
                mnum=1
                if mlen>int(sufficient_len) || uintptr(padd(ip,mlen))==uintptr(i_limit) {
                    ms.next_to_update=curr+1
                    return 1
                }
            }
        }
    }

    hash_table[h]=curr

    for ;nb_compares!=0 && match_index>=match_low;nb_compares-=1 {
        next_ptr:=([^]u32)(&bt[2*(match_index&bt_mask)])
        match_length:=min(common_length_smaller,common_length_larger)

        match:=padd(base,int(match_index))
        match_length+=count(padd(ip,match_length),padd(match,match_length),i_limit)

        if match_length>best_length {
            if match_length>int(match_end_idx-match_index) {
                match_end_idx=match_index+u32(match_length)
            }
            best_length=match_length
            matches[mnum].off=offset_to_offbase(curr-match_index)
            matches[mnum].len=u32(match_length)
            mnum+=1
            if match_length>OPT_NUM || uintptr(padd(ip,match_length))==uintptr(i_limit) {break}
        }

        if match[match_length]<ip[match_length] {
            smaller_ptr^=match_index
            common_length_smaller=match_length
            if match_index<=bt_low {smaller_ptr=&dummy32;break}
            smaller_ptr=&next_ptr[1]
            match_index=next_ptr[1]
        } else {
            larger_ptr^=match_index
            common_length_larger=match_length
            if match_index<=bt_low {larger_ptr=&dummy32;break}
            larger_ptr=&next_ptr[0]
            match_index=next_ptr[0]
        }
    }

    smaller_ptr^=0
    larger_ptr^=0

    ms.next_to_update=match_end_idx-8
    return mnum
}

@(private="file")
Get_All_Matches :: #type proc "contextless" (matches:[^]Match,ms:^Match_State,next_to_update3:^u32,ip,i_high_limit:[^]u8,rep:^[REP_NUM]u32,ll0,length_to_beat:u32) -> u32

@(private="file")
bt_get_all_matches_internal :: #force_inline proc "contextless" (matches:[^]Match,ms:^Match_State,next_to_update3:^u32,ip,i_high_limit:[^]u8,rep:^[REP_NUM]u32,ll0,length_to_beat,mls:u32) -> u32 {
    if uintptr(ip)<uintptr(padd(ms.window.base,int(ms.next_to_update))) {return 0}
    update_tree_internal(ms,ip,i_high_limit,mls)
    return insert_bt_and_get_all_matches(matches,ms,next_to_update3,ip,i_high_limit,rep,ll0,length_to_beat,mls)
}

@(private="file")
bt_get_all_matches_3 :: proc "contextless" (matches:[^]Match,ms:^Match_State,next_to_update3:^u32,ip,i_high_limit:[^]u8,rep:^[REP_NUM]u32,ll0,length_to_beat:u32) -> u32 {
    return bt_get_all_matches_internal(matches,ms,next_to_update3,ip,i_high_limit,rep,ll0,length_to_beat,3)
}

@(private="file")
bt_get_all_matches_4 :: proc "contextless" (matches:[^]Match,ms:^Match_State,next_to_update3:^u32,ip,i_high_limit:[^]u8,rep:^[REP_NUM]u32,ll0,length_to_beat:u32) -> u32 {
    return bt_get_all_matches_internal(matches,ms,next_to_update3,ip,i_high_limit,rep,ll0,length_to_beat,4)
}

@(private="file")
bt_get_all_matches_5 :: proc "contextless" (matches:[^]Match,ms:^Match_State,next_to_update3:^u32,ip,i_high_limit:[^]u8,rep:^[REP_NUM]u32,ll0,length_to_beat:u32) -> u32 {
    return bt_get_all_matches_internal(matches,ms,next_to_update3,ip,i_high_limit,rep,ll0,length_to_beat,5)
}

@(private="file")
bt_get_all_matches_6 :: proc "contextless" (matches:[^]Match,ms:^Match_State,next_to_update3:^u32,ip,i_high_limit:[^]u8,rep:^[REP_NUM]u32,ll0,length_to_beat:u32) -> u32 {
    return bt_get_all_matches_internal(matches,ms,next_to_update3,ip,i_high_limit,rep,ll0,length_to_beat,6)
}

@(private="file")
select_bt_get_all_matches :: #force_inline proc "contextless" (ms:^Match_State) -> Get_All_Matches {
    switch clamp(ms.c_params.min_match,3,6) {
    case 3: return bt_get_all_matches_3
    case 4: return bt_get_all_matches_4
    case 5: return bt_get_all_matches_5
    case: return bt_get_all_matches_6
    }
}

@(private="file")
lit_price :: #force_inline proc "contextless" (p:[^]u8,opt_state:^Opt_State,opt_level:int) -> i32 {
    return i32(raw_literals_cost(p,1,opt_state,opt_level))
}

@(private="file")
ll_price :: #force_inline proc "contextless" (l:u32,opt_state:^Opt_State,opt_level:int) -> i32 {
    return i32(lit_length_price(l,opt_state,opt_level))
}

@(private="file")
ll_inc_price :: #force_inline proc "contextless" (l:u32,opt_state:^Opt_State,opt_level:int) -> i32 {
    return ll_price(l,opt_state,opt_level)-ll_price(l-1,opt_state,opt_level)
}

@(private="file")
compress_block_opt_generic :: #force_inline proc "contextless" (ms:^Match_State,store:^Seq_Store,rep:^[REP_NUM]u32,src:[^]u8,src_size:int,opt_level:int) -> int #no_bounds_check {
    opt_state:=&ms.opt
    istart:=src
    ip:=istart
    anchor:=istart
    iend:=padd(istart,src_size)
    ilimit:=padd(iend,-8)
    base:=ms.window.base
    prefix_start:=padd(base,int(ms.window.dict_limit))
    c_params:=&ms.c_params

    get_all_matches:=select_bt_get_all_matches(ms)

    sufficient_len:=min(c_params.target_length,OPT_NUM-1)
    min_match:u32=c_params.min_match==3 ? 3 : 4
    next_to_update3:=ms.next_to_update

    opt:=opt_state.price_table
    matches:=opt_state.match_table
    last_stretch:Optimal

    rescale_freqs(opt_state,src,src_size,opt_level)
    if uintptr(ip)==uintptr(prefix_start) {ip=padd(ip,1)}

    main_loop: for uintptr(ip)<uintptr(ilimit) {
        cur,last_pos:u32=0,0

        forward: {
            {
                litlen:=u32(pdiff(ip,anchor))
                ll0:=to_u32(litlen==0)
                nb_matches:=get_all_matches(matches,ms,&next_to_update3,ip,iend,rep,ll0,min_match)
                if nb_matches==0 {
                    ip=padd(ip,1)
                    continue main_loop
                }

                // In this pass opt holds stretches: a match followed by literals.
                opt[0].mlen=0
                opt[0].litlen=litlen
                opt[0].price=ll_price(litlen,opt_state,opt_level)
                opt[0].rep=rep^

                {
                    max_ml:=matches[nb_matches-1].len
                    max_off_base:=matches[nb_matches-1].off

                    if max_ml>sufficient_len {
                        last_stretch.litlen=0
                        last_stretch.mlen=max_ml
                        last_stretch.off=max_off_base
                        cur=0
                        last_pos=max_ml
                        break forward
                    }
                }

                {
                    pos:u32=1
                    for ;pos<min_match;pos+=1 {
                        opt[pos].price=MAX_PRICE
                        opt[pos].mlen=0
                        opt[pos].litlen=litlen+pos
                    }
                    for match_nb:u32=0;match_nb<nb_matches;match_nb+=1 {
                        off_base:=matches[match_nb].off
                        end:=matches[match_nb].len
                        for ;pos<=end;pos+=1 {
                            match_price:=i32(get_match_price(off_base,pos,opt_state,opt_level))
                            sequence_price:=opt[0].price+match_price
                            opt[pos].mlen=pos
                            opt[pos].off=off_base
                            opt[pos].litlen=0
                            opt[pos].price=sequence_price+ll_price(0,opt_state,opt_level)
                        }
                    }
                    last_pos=pos-1
                    opt[pos].price=MAX_PRICE
                }
            }

            for cur=1;cur<=last_pos;cur+=1 {
                inr:=padd(ip,int(cur))

                {
                    litlen:=opt[cur-1].litlen+1
                    price:=opt[cur-1].price+lit_price(padd(ip,int(cur)-1),opt_state,opt_level)+ll_inc_price(litlen,opt_state,opt_level)
                    if price<=opt[cur].price {
                        prev_match:=opt[cur]
                        opt[cur]=opt[cur-1]
                        opt[cur].litlen=litlen
                        opt[cur].price=price
                        if opt_level>=1 && prev_match.litlen==0 && ll_inc_price(1,opt_state,opt_level)<0 && uintptr(padd(ip,int(cur)))<uintptr(iend) {
                            with_1_literal:=prev_match.price+lit_price(padd(ip,int(cur)),opt_state,opt_level)+ll_inc_price(1,opt_state,opt_level)
                            with_more_literals:=price+lit_price(padd(ip,int(cur)),opt_state,opt_level)+ll_inc_price(litlen+1,opt_state,opt_level)
                            if with_1_literal<with_more_literals && with_1_literal<opt[cur+1].price {
                                prev:=cur-prev_match.mlen
                                new_reps:=new_rep(opt[prev].rep,prev_match.off,to_u32(opt[prev].litlen==0))
                                opt[cur+1]=prev_match
                                opt[cur+1].rep=new_reps
                                opt[cur+1].litlen=1
                                opt[cur+1].price=with_1_literal
                                if last_pos<cur+1 {last_pos=cur+1}
                            }
                        }
                    }
                }

                if opt[cur].litlen==0 {
                    prev:=cur-opt[cur].mlen
                    new_reps:=new_rep(opt[prev].rep,opt[cur].off,to_u32(opt[prev].litlen==0))
                    opt[cur].rep=new_reps
                }

                if uintptr(inr)>uintptr(ilimit) {continue}

                if cur==last_pos {break}

                if opt_level==0 && opt[cur+1].price<=opt[cur].price+(BITCOST_MULTIPLIER/2) {continue}

                {
                    ll0:=to_u32(opt[cur].litlen==0)
                    previous_price:=opt[cur].price
                    base_price:=previous_price+ll_price(0,opt_state,opt_level)
                    nb_matches:=get_all_matches(matches,ms,&next_to_update3,inr,iend,&opt[cur].rep,ll0,min_match)

                    if nb_matches==0 {continue}

                    {
                        longest_ml:=matches[nb_matches-1].len

                        if longest_ml>sufficient_len || cur+longest_ml>=OPT_NUM || uintptr(padd(ip,int(cur)+int(longest_ml)))>=uintptr(iend) {
                            last_stretch.mlen=longest_ml
                            last_stretch.off=matches[nb_matches-1].off
                            last_stretch.litlen=0
                            last_pos=cur+longest_ml
                            break forward
                        }
                    }

                    for match_nb:u32=0;match_nb<nb_matches;match_nb+=1 {
                        offset:=matches[match_nb].off
                        last_ml:=matches[match_nb].len
                        start_ml:=match_nb>0 ? matches[match_nb-1].len+1 : min_match

                        for mlen:=last_ml;mlen>=start_ml;mlen-=1 {
                            pos:=cur+mlen
                            price:=base_price+i32(get_match_price(offset,mlen,opt_state,opt_level))

                            if pos>last_pos || price<opt[pos].price {
                                for last_pos<pos {
                                    last_pos+=1
                                    opt[last_pos].price=MAX_PRICE
                                    opt[last_pos].litlen=1
                                }
                                opt[pos].mlen=mlen
                                opt[pos].off=offset
                                opt[pos].litlen=0
                                opt[pos].price=price
                            } else {
                                if opt_level==0 {break}
                            }
                        }
                    }
                }
                opt[last_pos+1].price=MAX_PRICE
            }

            last_stretch=opt[last_pos]
            cur=last_pos-last_stretch.mlen
        }

        if last_stretch.mlen==0 {
            ip=padd(ip,int(last_pos))
            continue
        }

        if last_stretch.litlen==0 {
            rep^=new_rep(opt[cur].rep,last_stretch.off,to_u32(opt[cur].litlen==0))
        } else {
            rep^=last_stretch.rep
            cur-=last_stretch.litlen
        }

        {
            // Stored backwards from store_end, partially overwriting opt, now as sequences.
            store_end:=cur+2
            store_start:=store_end
            stretch_pos:=cur

            if last_stretch.litlen>0 {
                opt[store_end].litlen=last_stretch.litlen
                opt[store_end].mlen=0
                store_start=store_end-1
                opt[store_start]=last_stretch
            }
            {
                opt[store_end]=last_stretch
                store_start=store_end
            }
            for {
                next_stretch:=opt[stretch_pos]
                opt[store_start].litlen=next_stretch.litlen
                if next_stretch.mlen==0 {break}
                store_start-=1
                opt[store_start]=next_stretch
                stretch_pos-=next_stretch.litlen+next_stretch.mlen
            }

            for store_pos:=store_start;store_pos<=store_end;store_pos+=1 {
                llen:=opt[store_pos].litlen
                mlen:=opt[store_pos].mlen
                off_base:=opt[store_pos].off
                advance:=llen+mlen

                if mlen==0 {
                    ip=padd(anchor,int(llen))
                    continue
                }

                update_stats(opt_state,llen,anchor,off_base,mlen)
                store_seq(store,int(llen),anchor,iend,off_base,int(mlen))
                anchor=padd(anchor,int(advance))
                ip=anchor
            }

            set_base_prices(opt_state,opt_level)
        }
    }

    return pdiff(iend,anchor)
}

@(private="file")
compress_block_opt0 :: proc "contextless" (ms:^Match_State,store:^Seq_Store,rep:^[REP_NUM]u32,src:[^]u8,src_size:int) -> int {
    return compress_block_opt_generic(ms,store,rep,src,src_size,0)
}

@(private="file")
compress_block_opt2 :: proc "contextless" (ms:^Match_State,store:^Seq_Store,rep:^[REP_NUM]u32,src:[^]u8,src_size:int) -> int {
    return compress_block_opt_generic(ms,store,rep,src,src_size,2)
}

compress_block_btopt :: proc "contextless" (ms:^Match_State,store:^Seq_Store,rep:^[REP_NUM]u32,src:[^]u8,src_size:int) -> int {
    return compress_block_opt0(ms,store,rep,src,src_size)
}

// A first pass over the block, only for its statistics: the history is forgotten after it.
@(private="file")
init_stats_ultra :: proc "contextless" (ms:^Match_State,store:^Seq_Store,rep:^[REP_NUM]u32,src:[^]u8,src_size:int) {
    tmp_rep:=rep^

    compress_block_opt2(ms,store,&tmp_rep,src,src_size)

    reset_seq_store(store)
    ms.window.base=padd(ms.window.base,-src_size)
    ms.window.dict_limit+=u32(src_size)
    ms.window.low_limit=ms.window.dict_limit
    ms.next_to_update=ms.window.dict_limit
}

compress_block_btultra :: proc "contextless" (ms:^Match_State,store:^Seq_Store,rep:^[REP_NUM]u32,src:[^]u8,src_size:int) -> int {
    return compress_block_opt2(ms,store,rep,src,src_size)
}

compress_block_btultra2 :: proc "contextless" (ms:^Match_State,store:^Seq_Store,rep:^[REP_NUM]u32,src:[^]u8,src_size:int) -> int {
    curr:=u32(pdiff(src,ms.window.base))

    if ms.opt.lit_length_sum==0 && uintptr(store.sequences)==uintptr(store.sequences_start) && ms.window.dict_limit==ms.window.low_limit && curr==ms.window.dict_limit && src_size>PREDEF_THRESHOLD {
        init_stats_ultra(ms,store,rep,src,src_size)
    }

    return compress_block_opt2(ms,store,rep,src,src_size)
}
