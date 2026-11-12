#+private
package lz4

import "base:intrinsics"

// Positions of the encoder are offsets of src and dst.

OPTIMAL_ML :: (ML_MASK-1)+MINMATCH
OPT_NUM :: 1<<12
TRAILING_LITERALS :: 3
HC_HASH_LOG :: 15
HC_HASHTABLESIZE :: 1<<HC_HASH_LOG
HC_MAXD :: 1<<16
// The index of the first byte of the input.
HC_PREFIX_IDX :: u32(64*1024)

Strategy :: enum {Mid,Hc,Opt}

C_Params :: struct {strat:Strategy,nb_searches:int,target_length:int}

@(rodata) K_CL_TABLE:=[HC_CLEVEL_MAX+1]C_Params{
    {.Mid,2,16},
    {.Mid,2,16},
    {.Mid,2,16},
    {.Hc,4,16},
    {.Hc,8,16},
    {.Hc,16,16},
    {.Hc,32,16},
    {.Hc,64,16},
    {.Hc,128,16},
    {.Hc,256,16},
    {.Opt,96,64},
    {.Opt,512,128},
    {.Opt,16384,OPT_NUM},
}

Hc_Ctx :: struct {
    hash_table:[HC_HASHTABLESIZE]u32,
    chain_table:[HC_MAXD]u16,
    next_to_update:u32,
}

Hc_Match :: struct {off,len,back:int}

Hc_Optimal :: struct {price,off,mlen,litlen:int}

Repeat_State :: enum {Untested,Not,Confirmed}

hc_hash_ptr :: #force_inline proc "contextless" (p:uintptr) -> u32 {
    return (read32(p)*2654435761)>>((MINMATCH*8)-HC_HASH_LOG)
}

hc_nb_common_bytes32 :: #force_inline proc "contextless" (val:u32) -> int {return int(intrinsics.count_leading_zeros(val))>>3}

// A negative value: how many bytes before ip and match are equal.
hc_count_back :: #force_inline proc "contextless" (src:[^]u8,ip,match,i_min,m_min:int) -> int #no_bounds_check {
    back:=0
    lowest:=max(i_min-ip,m_min-match)
    for back-lowest>3 {
        v:=read32(at(src,ip+back-4))~read32(at(src,match+back-4))
        if v!=0 {return back-hc_nb_common_bytes32(v)}
        back-=4
    }
    for back>lowest && src[ip+back-1]==src[match+back-1] {back-=1}
    return back
}

hc_encode_sequence :: #force_inline proc "contextless" (src,dst:[^]u8,ip,op,anchor:^int,match_length,offset:int,limit:bool,oend:int) -> (failed:bool) #no_bounds_check {
    token:=op^
    op^+=1

    length:=ip^-anchor^
    if limit && op^+length/255+length+(2+1+LASTLITERALS)>oend {return true}
    if length>=RUN_MASK {
        rest:=length-RUN_MASK
        dst[token]=RUN_MASK<<ML_BITS
        for ;rest>=255;rest-=255 {
            dst[op^]=255
            op^+=1
        }
        dst[op^]=u8(rest)
        op^+=1
    } else {
        dst[token]=u8(length<<ML_BITS)
    }

    wild_copy8(at(dst,op^),at(src,anchor^),at(dst,op^+length))
    op^+=length

    write16(at(dst,op^),u16(offset))
    op^+=2

    length=match_length-MINMATCH
    if limit && op^+length/255+(1+LASTLITERALS)>oend {return true}
    if length>=ML_MASK {
        dst[token]+=ML_MASK
        length-=ML_MASK
        for ;length>=510;length-=510 {
            dst[op^]=255
            dst[op^+1]=255
            op^+=2
        }
        if length>=255 {
            length-=255
            dst[op^]=255
            op^+=1
        }
        dst[op^]=u8(length)
        op^+=1
    } else {
        dst[token]+=u8(length)
    }

    ip^+=match_length
    anchor^=ip^
    return false
}

// Writes the last literals and returns the size of the block, 0 when dst is too small.
hc_last_literals :: #force_inline proc "contextless" (src,dst:[^]u8,anchor,iend,op,oend:int,limit:bool) -> int #no_bounds_check {
    op:=op
    last_run_size:=iend-anchor
    ll_add:=(last_run_size+255-RUN_MASK)/255
    total_size:=1+ll_add+last_run_size
    if limit && op+total_size>oend {return 0}
    if last_run_size>=RUN_MASK {
        accumulator:=last_run_size-RUN_MASK
        dst[op]=RUN_MASK<<ML_BITS
        op+=1
        for ;accumulator>=255;accumulator-=255 {
            dst[op]=255
            op+=1
        }
        dst[op]=u8(accumulator)
        op+=1
    } else {
        dst[op]=u8(last_run_size<<ML_BITS)
        op+=1
    }
    intrinsics.mem_copy_non_overlapping(rawptr(at(dst,op)),rawptr(at(src,anchor)),last_run_size)
    op+=last_run_size
    return op
}

hc_insert :: #force_inline proc "contextless" (hc:^Hc_Ctx,src:[^]u8,ip:int) #no_bounds_check {
    target:=u32(ip)+HC_PREFIX_IDX
    idx:=hc.next_to_update
    for idx<target {
        h:=hc_hash_ptr(at(src,int(idx-HC_PREFIX_IDX)))
        delta:=idx-hc.hash_table[h]
        if delta>DISTANCE_MAX {delta=DISTANCE_MAX}
        hc.chain_table[u16(idx)]=u16(delta)
        hc.hash_table[h]=idx
        idx+=1
    }
    hc.next_to_update=target
}

// pattern32 is a sample of a repetitive pattern of length 1, 2 or 4.
hc_count_pattern :: proc "contextless" (src:[^]u8,ip,i_end:int,pattern32:u32) -> int #no_bounds_check {
    ip:=ip
    i_start:=ip
    pattern:=u64(pattern32)+(u64(pattern32)<<32)
    for ip<i_end-7 {
        diff:=read64(at(src,ip))~pattern
        if diff==0 {
            ip+=8
            continue
        }
        ip+=nb_common_bytes(diff)
        return ip-i_start
    }
    pattern_byte:=pattern
    for ip<i_end && src[ip]==u8(pattern_byte) {
        ip+=1
        pattern_byte>>=8
    }
    return ip-i_start
}

hc_reverse_count_pattern :: proc "contextless" (src:[^]u8,ip,i_low:int,pattern:u32) -> int #no_bounds_check {
    ip:=ip
    i_start:=ip
    for ip>=i_low+4 {
        if read32(at(src,ip-4))!=pattern {break}
        ip-=4
    }
    pattern_bytes:=pattern
    for ip>i_low {
        if src[ip-1]!=u8(pattern_bytes>>24) {break}
        ip-=1
        pattern_bytes<<=8
    }
    return i_start-ip
}

hc_insert_and_get_wider_match :: #force_inline proc "contextless" (hc:^Hc_Ctx,src:[^]u8,ip,i_low_limit,i_high_limit,longest,max_nb_attempts:int,pattern_analysis,chain_swap:bool) -> Hc_Match #no_bounds_check {
    longest:=longest
    ip_index:=u32(ip)+HC_PREFIX_IDX
    within_start_distance:=HC_PREFIX_IDX+(DISTANCE_MAX+1)>ip_index
    lowest_match_index:=within_start_distance?HC_PREFIX_IDX:ip_index-DISTANCE_MAX
    look_back_length:=ip-i_low_limit
    nb_attempts:=max_nb_attempts
    match_chain_pos:=u32(0)
    pattern:=read32(at(src,ip))
    repeat:=Repeat_State.Untested
    src_pattern_length:=0
    offset,s_back:=0,0

    hc_insert(hc,src,ip)
    match_index:=hc.hash_table[hc_hash_ptr(at(src,ip))]

    search: for match_index>=lowest_match_index && nb_attempts>0 {
        match_length:=0
        nb_attempts-=1
        match_ptr:=int(match_index-HC_PREFIX_IDX)
        if read16(at(src,i_low_limit+longest-1))==read16(at(src,match_ptr-look_back_length+longest-1)) {
            if read32(at(src,match_ptr))==pattern {
                back:=look_back_length!=0?hc_count_back(src,ip,match_ptr,i_low_limit,0):0
                match_length=MINMATCH+count(src,ip+MINMATCH,match_ptr+MINMATCH,i_high_limit)
                match_length-=back
                if match_length>longest {
                    longest=match_length
                    offset=int(ip_index-match_index)
                    s_back=back
                }
            }
        }

        if chain_swap && match_length==longest {
            if match_index+u32(longest)<=ip_index {
                K_TRIGGER :: 4
                distance_to_next_match:=u32(1)
                end:=longest-MINMATCH+1
                step:=1
                accel:=1<<K_TRIGGER
                for pos:=0;pos<end;pos+=step {
                    candidate_dist:=u32(hc.chain_table[u16(match_index+u32(pos))])
                    step=accel>>K_TRIGGER
                    accel+=1
                    if candidate_dist>distance_to_next_match {
                        distance_to_next_match=candidate_dist
                        match_chain_pos=u32(pos)
                        accel=1<<K_TRIGGER
                    }
                }
                if distance_to_next_match>1 {
                    if distance_to_next_match>match_index {break search}
                    match_index-=distance_to_next_match
                    continue search
                }
            }
        }

        dist_next_match:=u32(hc.chain_table[u16(match_index)])
        if pattern_analysis && dist_next_match==1 && match_chain_pos==0 {
            match_candidate_idx:=match_index-1
            if repeat==.Untested {
                if (pattern&0xFFFF)==(pattern>>16) && (pattern&0xFF)==(pattern>>24) {
                    repeat=.Confirmed
                    src_pattern_length=hc_count_pattern(src,ip+4,i_high_limit,pattern)+4
                } else {
                    repeat=.Not
                }
            }
            if repeat==.Confirmed && match_candidate_idx>=lowest_match_index {
                candidate_ptr:=int(match_candidate_idx-HC_PREFIX_IDX)
                if read32(at(src,candidate_ptr))==pattern {
                    forward_pattern_length:=hc_count_pattern(src,candidate_ptr+4,i_high_limit,pattern)+4
                    back_length:=hc_reverse_count_pattern(src,candidate_ptr,0,pattern)
                    back_length=int(match_candidate_idx-max(match_candidate_idx-u32(back_length),lowest_match_index))
                    current_segment_length:=back_length+forward_pattern_length
                    if current_segment_length>=src_pattern_length && forward_pattern_length<=src_pattern_length {
                        match_index=match_candidate_idx+u32(forward_pattern_length)-u32(src_pattern_length)
                    } else {
                        match_index=match_candidate_idx-u32(back_length)
                        if look_back_length==0 {
                            max_ml:=min(current_segment_length,src_pattern_length)
                            if longest<max_ml {
                                if ip+int(HC_PREFIX_IDX)-int(match_index)>DISTANCE_MAX {break search}
                                longest=max_ml
                                offset=int(ip_index-match_index)
                            }
                            dist_to_next_pattern:=u32(hc.chain_table[u16(match_index)])
                            if dist_to_next_pattern>match_index {break search}
                            match_index-=dist_to_next_pattern
                        }
                    }
                    continue search
                }
            }
        }

        match_index-=u32(hc.chain_table[u16(match_index+match_chain_pos)])
    }

    return {off=offset,len=longest,back=s_back}
}

hc_compress_hash_chain :: proc "contextless" (hc:^Hc_Ctx,src,dst:[^]u8,input_size,max_output_size,max_nb_attempts:int,limit:bool) -> int #no_bounds_check {
    pattern_analysis:=max_nb_attempts>128
    ip,anchor,op:=0,0,0
    iend:=input_size
    mflimit:=iend-MFLIMIT
    matchlimit:=iend-LASTLITERALS
    oend:=max_output_size
    start0,start2,start3:int
    m0,m1,m2,m3:Hc_Match

    if input_size>=MIN_LENGTH {
        main: for ip<=mflimit {
            m1=hc_insert_and_get_wider_match(hc,src,ip,ip,matchlimit,MINMATCH-1,max_nb_attempts,pattern_analysis,false)
            if m1.len<MINMATCH {
                ip+=1
                continue main
            }

            start0=ip
            m0=m1

            search2: for {
                if ip+m1.len<=mflimit {
                    start2=ip+m1.len-2
                    m2=hc_insert_and_get_wider_match(hc,src,start2,ip,matchlimit,m1.len,max_nb_attempts,pattern_analysis,false)
                    start2+=m2.back
                } else {
                    m2={}
                }

                if m2.len<=m1.len {
                    if hc_encode_sequence(src,dst,&ip,&op,&anchor,m1.len,m1.off,limit,oend) {return 0}
                    continue main
                }

                if start0<ip && start2<ip+m0.len {
                    ip=start0
                    m1=m0
                }

                if start2-ip<3 {
                    ip=start2
                    m1=m2
                    continue search2
                }

                search3: for {
                    if start2-ip<OPTIMAL_ML {
                        new_ml:=m1.len
                        if new_ml>OPTIMAL_ML {new_ml=OPTIMAL_ML}
                        if ip+new_ml>start2+m2.len-MINMATCH {new_ml=start2-ip+m2.len-MINMATCH}
                        correction:=new_ml-(start2-ip)
                        if correction>0 {
                            start2+=correction
                            m2.len-=correction
                        }
                    }

                    if start2+m2.len<=mflimit {
                        start3=start2+m2.len-3
                        m3=hc_insert_and_get_wider_match(hc,src,start3,start2,matchlimit,m2.len,max_nb_attempts,pattern_analysis,false)
                        start3+=m3.back
                    } else {
                        m3={}
                    }

                    if m3.len<=m2.len {
                        if start2<ip+m1.len {m1.len=start2-ip}
                        if hc_encode_sequence(src,dst,&ip,&op,&anchor,m1.len,m1.off,limit,oend) {return 0}
                        ip=start2
                        if hc_encode_sequence(src,dst,&ip,&op,&anchor,m2.len,m2.off,limit,oend) {return 0}
                        continue main
                    }

                    if start3<ip+m1.len+3 {
                        if start3>=ip+m1.len {
                            if start2<ip+m1.len {
                                correction:=ip+m1.len-start2
                                start2+=correction
                                m2.len-=correction
                                if m2.len<MINMATCH {
                                    start2=start3
                                    m2=m3
                                }
                            }

                            if hc_encode_sequence(src,dst,&ip,&op,&anchor,m1.len,m1.off,limit,oend) {return 0}
                            ip=start3
                            m1=m3

                            start0=start2
                            m0=m2
                            continue search2
                        }

                        start2=start3
                        m2=m3
                        continue search3
                    }

                    if start2<ip+m1.len {
                        if start2-ip<OPTIMAL_ML {
                            if m1.len>OPTIMAL_ML {m1.len=OPTIMAL_ML}
                            if ip+m1.len>start2+m2.len-MINMATCH {m1.len=start2-ip+m2.len-MINMATCH}
                            correction:=m1.len-(start2-ip)
                            if correction>0 {
                                start2+=correction
                                m2.len-=correction
                            }
                        } else {
                            m1.len=start2-ip
                        }
                    }
                    if hc_encode_sequence(src,dst,&ip,&op,&anchor,m1.len,m1.off,limit,oend) {return 0}

                    ip=start2
                    m1=m2

                    start2=start3
                    m2=m3
                }
            }
        }
    }

    return hc_last_literals(src,dst,anchor,iend,op,oend,limit)
}

hc_literals_price :: #force_inline proc "contextless" (litlen:int) -> int {
    price:=litlen
    if litlen>=RUN_MASK {price+=1+(litlen-RUN_MASK)/255}
    return price
}

hc_sequence_price :: #force_inline proc "contextless" (litlen,mlen:int) -> int {
    price:=1+2+hc_literals_price(litlen)
    if mlen>=ML_MASK+MINMATCH {price+=1+(mlen-(ML_MASK+MINMATCH))/255}
    return price
}

hc_find_longer_match :: #force_inline proc "contextless" (hc:^Hc_Ctx,src:[^]u8,ip,i_high_limit,min_len,nb_searches:int) -> Hc_Match {
    md:=hc_insert_and_get_wider_match(hc,src,ip,ip,i_high_limit,min_len,nb_searches,true,true)
    if md.len<=min_len {return {}}
    return md
}

hc_compress_optimal :: proc(hc:^Hc_Ctx,src,dst:[^]u8,src_size,dst_capacity,nb_searches,sufficient_len:int,limit,full_update:bool,allocator:=context.allocator) -> int #no_bounds_check {
    opt_buffer,opt_error:=make([]Hc_Optimal,OPT_NUM+TRAILING_LITERALS,allocator)
    if opt_error!=nil {return 0}
    opt:=raw_data(opt_buffer)
    defer delete(opt_buffer,allocator)

    sufficient_len:=sufficient_len
    ip,anchor,op:=0,0,0
    iend:=src_size
    mflimit:=iend-MFLIMIT
    matchlimit:=iend-LASTLITERALS
    oend:=dst_capacity

    if sufficient_len>=OPT_NUM {sufficient_len=OPT_NUM-1}

    for ip<=mflimit {
        llen:=ip-anchor
        best_mlen,best_off:int
        cur,last_match_pos:=0,0

        first_match:=hc_find_longer_match(hc,src,ip,matchlimit,MINMATCH-1,nb_searches)
        if first_match.len==0 {
            ip+=1
            continue
        }

        if first_match.len>sufficient_len {
            if hc_encode_sequence(src,dst,&ip,&op,&anchor,first_match.len,first_match.off,limit,oend) {return 0}
            continue
        }

        for r_pos in 0..<MINMATCH {
            opt[r_pos]={price=hc_literals_price(llen+r_pos),off=0,mlen=1,litlen=llen+r_pos}
        }
        for mlen:=MINMATCH;mlen<=first_match.len;mlen+=1 {
            opt[mlen]={price=hc_sequence_price(llen,mlen),off=first_match.off,mlen=mlen,litlen=llen}
        }
        last_match_pos=first_match.len
        for add_lit:=1;add_lit<=TRAILING_LITERALS;add_lit+=1 {
            opt[last_match_pos+add_lit]={price=opt[last_match_pos].price+hc_literals_price(add_lit),off=0,mlen=1,litlen=add_lit}
        }

        found_immediate:=false
        for cur=1;cur<last_match_pos;cur+=1 {
            cur_ptr:=ip+cur
            if cur_ptr>mflimit {break}
            if full_update {
                if opt[cur+1].price<=opt[cur].price && opt[cur+MINMATCH].price<opt[cur].price+3 {continue}
            } else {
                if opt[cur+1].price<=opt[cur].price {continue}
            }

            new_match:Hc_Match
            if full_update {
                new_match=hc_find_longer_match(hc,src,cur_ptr,matchlimit,MINMATCH-1,nb_searches)
            } else {
                new_match=hc_find_longer_match(hc,src,cur_ptr,matchlimit,last_match_pos-cur,nb_searches)
            }
            if new_match.len==0 {continue}

            if new_match.len>sufficient_len || new_match.len+cur>=OPT_NUM {
                best_mlen=new_match.len
                best_off=new_match.off
                last_match_pos=cur+1
                found_immediate=true
                break
            }

            base_litlen:=opt[cur].litlen
            for litlen:=1;litlen<MINMATCH;litlen+=1 {
                price:=opt[cur].price-hc_literals_price(base_litlen)+hc_literals_price(base_litlen+litlen)
                pos:=cur+litlen
                if price<opt[pos].price {
                    opt[pos]={price=price,off=0,mlen=1,litlen=base_litlen+litlen}
                }
            }

            match_ml:=new_match.len
            for ml:=MINMATCH;ml<=match_ml;ml+=1 {
                pos:=cur+ml
                offset:=new_match.off
                price,ll:int
                if opt[cur].mlen==1 {
                    ll=opt[cur].litlen
                    price=(cur>ll?opt[cur-ll].price:0)+hc_sequence_price(ll,ml)
                } else {
                    ll=0
                    price=opt[cur].price+hc_sequence_price(0,ml)
                }

                if pos>last_match_pos+TRAILING_LITERALS || price<=opt[pos].price {
                    if ml==match_ml && last_match_pos<pos {last_match_pos=pos}
                    opt[pos]={price=price,off=offset,mlen=ml,litlen=ll}
                }
            }
            for add_lit:=1;add_lit<=TRAILING_LITERALS;add_lit+=1 {
                opt[last_match_pos+add_lit]={price=opt[last_match_pos].price+hc_literals_price(add_lit),off=0,mlen=1,litlen=add_lit}
            }
        }

        if !found_immediate {
            best_mlen=opt[last_match_pos].mlen
            best_off=opt[last_match_pos].off
            cur=last_match_pos-best_mlen
        }

        candidate_pos:=cur
        selected_match_length:=best_mlen
        selected_offset:=best_off
        for {
            next_match_length:=opt[candidate_pos].mlen
            next_offset:=opt[candidate_pos].off
            opt[candidate_pos].mlen=selected_match_length
            opt[candidate_pos].off=selected_offset
            selected_match_length=next_match_length
            selected_offset=next_offset
            if next_match_length>candidate_pos {break}
            candidate_pos-=next_match_length
        }

        r_pos:=0
        for r_pos<last_match_pos {
            ml:=opt[r_pos].mlen
            offset:=opt[r_pos].off
            if ml==1 {
                ip+=1
                r_pos+=1
                continue
            }
            r_pos+=ml
            if hc_encode_sequence(src,dst,&ip,&op,&anchor,ml,offset,limit,oend) {return 0}
        }
    }

    return hc_last_literals(src,dst,anchor,iend,op,oend,limit)
}
