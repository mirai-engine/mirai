package zstd

import "base:intrinsics"

@(private="file") LAZY_SEARCH_STRENGTH :: 8
@(private="file") LAZY_SKIPPING_STEP :: 8
@(private="file") ROW_HASH_TAG_BITS :: 8
@(private="file") ROW_HASH_TAG_MASK :: u32((1<<ROW_HASH_TAG_BITS)-1)
@(private="file") ROW_HASH_MAX_ENTRIES :: 64
@(private="file") ROW_HASH_CACHE_MASK :: ROW_HASH_CACHE_SIZE-1
@(private="file") ABSENT_OFF_BASE :: u32(999999999)

@(private="file") X01 :: u64(0x0101010101010101)
@(private="file") X80 :: u64(0x8080808080808080)
@(private="file") EXTRACT_MAGIC :: (u64(0xFFFFFFFFFFFFFFFF)/0x7F)>>8

@(private="file")
insert_and_find_first_index_internal :: #force_inline proc "contextless" (ms:^Match_State,ip:[^]u8,mls:u32,lazy_skipping:bool) -> u32 {
    hash_table:=ms.hash_table
    hash_log:=ms.c_params.hash_log
    chain_table:=ms.chain_table
    chain_mask:=(u32(1)<<ms.c_params.chain_log)-1
    base:=ms.window.base
    target:=u32(pdiff(ip,base))
    idx:=ms.next_to_update

    for idx<target {
        h:=hash_ptr(padd(base,int(idx)),hash_log,mls)
        chain_table[idx&chain_mask]=hash_table[h]
        hash_table[h]=idx
        idx+=1
        if lazy_skipping {break}
    }

    ms.next_to_update=target
    return hash_table[hash_ptr(ip,hash_log,mls)]
}

@(private="file")
hc_find_best_match :: #force_no_inline proc "contextless" (ms:^Match_State,ip,i_limit:[^]u8,offset_ptr:^u32,$MLS:u32) -> int {
    chain_table:=ms.chain_table
    chain_size:=u32(1)<<ms.c_params.chain_log
    chain_mask:=chain_size-1
    base:=ms.window.base
    curr:=u32(pdiff(ip,base))
    low_limit:=get_lowest_match_index(ms,curr,ms.c_params.window_log)
    min_chain:=curr>chain_size ? curr-chain_size : 0
    nb_attempts:=u32(1)<<ms.c_params.search_log
    ml:=4-1

    match_index:=insert_and_find_first_index_internal(ms,ip,MLS,ms.lazy_skipping)

    for ;match_index>=low_limit && nb_attempts>0;nb_attempts-=1 {
        current_ml:=0
        match:=padd(base,int(match_index))
        if read32(padd(match,ml-3))==read32(padd(ip,ml-3)) {
            current_ml=count(ip,match,i_limit)
        }

        if current_ml>ml {
            ml=current_ml
            offset_ptr^=offset_to_offbase(curr-match_index)
            if uintptr(padd(ip,current_ml))==uintptr(i_limit) {break}
        }

        if match_index<=min_chain {break}
        match_index=chain_table[match_index&chain_mask]
    }

    return ml
}

@(private="file")
row_next_index :: #force_inline proc "contextless" (tag_row:[^]u8,row_mask:u32) -> u32 {
    next:=(u32(tag_row[0])-1)&row_mask
    if next==0 {next+=row_mask}
    tag_row[0]=u8(next)
    return next
}

@(private="file")
row_prefetch :: #force_inline proc "contextless" (hash_table:[^]u32,tag_table:[^]u8,rel_row,row_log:u32) {
    intrinsics.prefetch_read_data(&hash_table[rel_row],3)
    if row_log>=5 {intrinsics.prefetch_read_data(&hash_table[rel_row+16],3)}
    intrinsics.prefetch_read_data(&tag_table[rel_row],3)
    if row_log==6 {intrinsics.prefetch_read_data(&tag_table[rel_row+32],3)}
}

@(private="file")
row_fill_hash_cache :: #force_inline proc "contextless" (ms:^Match_State,base:[^]u8,row_log,mls,start:u32,i_limit:[^]u8) #no_bounds_check {
    hash_table:=ms.hash_table
    tag_table:=ms.tag_table
    hash_log:=ms.row_hash_log
    at:=padd(base,int(start))
    max_elems_to_prefetch:=uintptr(at)>uintptr(i_limit) ? 0 : u32(pdiff(i_limit,at)+1)
    lim:=start+min(ROW_HASH_CACHE_SIZE,max_elems_to_prefetch)

    for idx:=start;idx<lim;idx+=1 {
        hash:=u32(hash_ptr_salted(padd(base,int(idx)),hash_log+ROW_HASH_TAG_BITS,mls,ms.hash_salt))
        row:=(hash>>ROW_HASH_TAG_BITS)<<row_log
        row_prefetch(hash_table,tag_table,row,row_log)
        ms.hash_cache[idx&ROW_HASH_CACHE_MASK]=hash
    }
}

@(private="file")
row_next_cached_hash :: #force_inline proc "contextless" (cache:^[ROW_HASH_CACHE_SIZE]u32,hash_table:[^]u32,tag_table,base:[^]u8,idx,hash_log,row_log,mls:u32,hash_salt:u64) -> u32 #no_bounds_check {
    new_hash:=u32(hash_ptr_salted(padd(base,int(idx)+ROW_HASH_CACHE_SIZE),hash_log+ROW_HASH_TAG_BITS,mls,hash_salt))
    row:=(new_hash>>ROW_HASH_TAG_BITS)<<row_log
    row_prefetch(hash_table,tag_table,row,row_log)
    hash:=cache[idx&ROW_HASH_CACHE_MASK]
    cache[idx&ROW_HASH_CACHE_MASK]=new_hash
    return hash
}

@(private="file")
row_update_internal_impl :: #force_inline proc "contextless" (ms:^Match_State,update_start_idx,update_end_idx,mls,row_log,row_mask:u32,use_cache:bool) {
    hash_table:=ms.hash_table
    tag_table:=ms.tag_table
    hash_log:=ms.row_hash_log
    base:=ms.window.base

    for idx:=update_start_idx;idx<update_end_idx;idx+=1 {
        hash:=use_cache ? row_next_cached_hash(&ms.hash_cache,hash_table,tag_table,base,idx,hash_log,row_log,mls,ms.hash_salt) : u32(hash_ptr_salted(padd(base,int(idx)),hash_log+ROW_HASH_TAG_BITS,mls,ms.hash_salt))
        rel_row:=(hash>>ROW_HASH_TAG_BITS)<<row_log
        row:=([^]u32)(&hash_table[rel_row])
        tag_row:=([^]u8)(&tag_table[rel_row])
        pos:=row_next_index(tag_row,row_mask)

        tag_row[pos]=u8(hash&ROW_HASH_TAG_MASK)
        row[pos]=idx
    }
}

@(private="file")
row_update_internal :: #force_inline proc "contextless" (ms:^Match_State,ip:[^]u8,mls,row_log,row_mask:u32,use_cache:bool) {
    idx:=ms.next_to_update
    base:=ms.window.base
    target:=u32(pdiff(ip,base))
    SKIP_THRESHOLD :: 384
    MAX_MATCH_START_POSITIONS_TO_UPDATE :: 96
    MAX_MATCH_END_POSITIONS_TO_UPDATE :: 32

    if use_cache {
        if target-idx>SKIP_THRESHOLD {
            bound:=idx+MAX_MATCH_START_POSITIONS_TO_UPDATE
            row_update_internal_impl(ms,idx,bound,mls,row_log,row_mask,use_cache)
            idx=target-MAX_MATCH_END_POSITIONS_TO_UPDATE
            row_fill_hash_cache(ms,base,row_log,mls,idx,padd(ip,1))
        }
    }
    row_update_internal_impl(ms,idx,target,mls,row_log,row_mask,use_cache)
    ms.next_to_update=target
}

row_update :: proc "contextless" (ms:^Match_State,ip:[^]u8) {
    row_log:=clamp(ms.c_params.search_log,4,6)
    row_mask:=(u32(1)<<row_log)-1
    mls:=min(ms.c_params.min_match,6)

    row_update_internal(ms,ip,mls,row_log,row_mask,false)
}

// Bit n is set when the tag at entry n of the row, counted from head, equals tag.
@(private="file")
row_get_match_mask :: #force_inline proc "contextless" (tag_row:[^]u8,tag:u8,head,row_entries:u32) -> u64 {
    splat:=u64(tag)*X01
    matches:u64=0
    i:=int(row_entries)-8
    for {
        chunk:=read64(padd(tag_row,i))~splat
        chunk=(((chunk|X80)-X01)|chunk)&X80
        matches<<=8
        matches|=(chunk*EXTRACT_MAGIC)>>56
        i-=8
        if i<0 {break}
    }
    matches=~matches
    switch row_entries {
    case 16: return u64(rotr16(u16(matches),head))
    case 32: return u64(rotr32(u32(matches),head))
    case: return rotr64(matches,head)
    }
}

@(private="file")
row_find_best_match :: #force_no_inline proc "contextless" (ms:^Match_State,ip,i_limit:[^]u8,offset_ptr:^u32,$MLS:u32,$ROW_LOG:u32) -> int #no_bounds_check {
    hash_table:=ms.hash_table
    tag_table:=ms.tag_table
    hash_log:=ms.row_hash_log
    base:=ms.window.base
    curr:=u32(pdiff(ip,base))
    low_limit:=get_lowest_match_index(ms,curr,ms.c_params.window_log)
    row_entries:=u32(1)<<ROW_LOG
    row_mask:=row_entries-1
    capped_search_log:=min(ms.c_params.search_log,ROW_LOG)
    hash_salt:=ms.hash_salt
    nb_attempts:=u32(1)<<capped_search_log
    ml:=4-1
    hash:u32

    if !ms.lazy_skipping {
        row_update_internal(ms,ip,MLS,ROW_LOG,row_mask,true)
        hash=row_next_cached_hash(&ms.hash_cache,hash_table,tag_table,base,curr,hash_log,ROW_LOG,MLS,hash_salt)
    } else {
        hash=u32(hash_ptr_salted(ip,hash_log+ROW_HASH_TAG_BITS,MLS,hash_salt))
        ms.next_to_update=curr
    }
    ms.hash_salt_entropy+=hash

    rel_row:=(hash>>ROW_HASH_TAG_BITS)<<ROW_LOG
    tag:=hash&ROW_HASH_TAG_MASK
    row:=([^]u32)(&hash_table[rel_row])
    tag_row:=([^]u8)(&tag_table[rel_row])
    head:=u32(tag_row[0])&row_mask
    match_buffer:[ROW_HASH_MAX_ENTRIES]u32=---
    num_matches:=0
    matches:=row_get_match_mask(tag_row,u8(tag),head,row_entries)

    for ;matches>0 && nb_attempts>0;matches&=(matches-1) {
        match_pos:=(head+ctz64(matches))&row_mask
        match_index:=row[match_pos]
        if match_pos==0 {continue}
        if match_index<low_limit {break}
        intrinsics.prefetch_read_data(padd(base,int(match_index)),3)
        match_buffer[num_matches]=match_index
        num_matches+=1
        nb_attempts-=1
    }

    {
        pos:=row_next_index(tag_row,row_mask)
        tag_row[pos]=u8(tag)
        row[pos]=ms.next_to_update
        ms.next_to_update+=1
    }

    for curr_match:=0;curr_match<num_matches;curr_match+=1 {
        match_index:=match_buffer[curr_match]
        current_ml:=0
        match:=padd(base,int(match_index))

        if read32(padd(match,ml-3))==read32(padd(ip,ml-3)) {
            current_ml=count(ip,match,i_limit)
        }

        if current_ml>ml {
            ml=current_ml
            offset_ptr^=offset_to_offbase(curr-match_index)
            if uintptr(padd(ip,current_ml))==uintptr(i_limit) {break}
        }
    }

    return ml
}

@(private="file") Search_Method :: enum {Hash_Chain,Row_Hash}

@(private="file")
search_max :: #force_inline proc "contextless" (ms:^Match_State,ip,iend:[^]u8,offset_ptr:^u32,mls,row_log:u32,method:Search_Method) -> int {
    if method==.Hash_Chain {
        switch mls {
        case 4: return hc_find_best_match(ms,ip,iend,offset_ptr,4)
        case 5: return hc_find_best_match(ms,ip,iend,offset_ptr,5)
        case: return hc_find_best_match(ms,ip,iend,offset_ptr,6)
        }
    }
    switch mls {
    case 4:
        switch row_log {
        case 4: return row_find_best_match(ms,ip,iend,offset_ptr,4,4)
        case 5: return row_find_best_match(ms,ip,iend,offset_ptr,4,5)
        case: return row_find_best_match(ms,ip,iend,offset_ptr,4,6)
        }
    case 5:
        switch row_log {
        case 4: return row_find_best_match(ms,ip,iend,offset_ptr,5,4)
        case 5: return row_find_best_match(ms,ip,iend,offset_ptr,5,5)
        case: return row_find_best_match(ms,ip,iend,offset_ptr,5,6)
        }
    case:
        switch row_log {
        case 4: return row_find_best_match(ms,ip,iend,offset_ptr,6,4)
        case 5: return row_find_best_match(ms,ip,iend,offset_ptr,6,5)
        case: return row_find_best_match(ms,ip,iend,offset_ptr,6,6)
        }
    }
}

@(private="file")
compress_block_lazy_generic :: #force_inline proc "contextless" (ms:^Match_State,store:^Seq_Store,rep:^[REP_NUM]u32,src:[^]u8,src_size:int,method:Search_Method,depth:u32) -> int {
    istart:=src
    ip:=istart
    anchor:=istart
    iend:=padd(istart,src_size)
    ilimit:=method==.Row_Hash ? padd(iend,-8-ROW_HASH_CACHE_SIZE) : padd(iend,-8)
    base:=ms.window.base
    prefix_lowest_index:=ms.window.dict_limit
    prefix_lowest:=padd(base,int(prefix_lowest_index))
    mls:=clamp(ms.c_params.min_match,4,6)
    row_log:=clamp(ms.c_params.search_log,4,6)

    offset_1,offset_2:=rep[0],rep[1]
    offset_saved1,offset_saved2:u32=0,0

    if u32(pdiff(ip,prefix_lowest))==0 {ip=padd(ip,1)}
    {
        curr:=u32(pdiff(ip,base))
        window_low:=get_lowest_prefix_index(ms,curr,ms.c_params.window_log)
        max_rep:=curr-window_low
        if offset_2>max_rep {offset_saved2=offset_2;offset_2=0}
        if offset_1>max_rep {offset_saved1=offset_1;offset_1=0}
    }

    ms.lazy_skipping=false

    if method==.Row_Hash {
        row_fill_hash_cache(ms,base,row_log,mls,ms.next_to_update,ilimit)
    }

    match_loop: for uintptr(ip)<uintptr(ilimit) {
        match_length:=0
        off_base:=repcode_to_offbase(1)
        start:=padd(ip,1)

        search: {
            if offset_1>0 && read32(padd(ip,1-int(offset_1)))==read32(padd(ip,1)) {
                match_length=count(padd(ip,1+4),padd(ip,1+4-int(offset_1)),iend)+4
                if depth==0 {break search}
            }

            {
                offbase_found:=ABSENT_OFF_BASE
                ml2:=search_max(ms,ip,iend,&offbase_found,mls,row_log,method)
                if ml2>match_length {
                    match_length=ml2
                    start=ip
                    off_base=offbase_found
                }
            }

            if match_length<4 {
                step:=(pdiff(ip,anchor)>>LAZY_SEARCH_STRENGTH)+1
                ip=padd(ip,step)
                ms.lazy_skipping=step>LAZY_SKIPPING_STEP
                continue match_loop
            }

            if depth>=1 {
                for uintptr(ip)<uintptr(ilimit) {
                    ip=padd(ip,1)
                    if off_base!=0 && offset_1>0 && read32(ip)==read32(padd(ip,-int(offset_1))) {
                        ml_rep:=count(padd(ip,4),padd(ip,4-int(offset_1)),iend)+4
                        gain2:=ml_rep*3
                        gain1:=match_length*3-int(highbit32(off_base))+1
                        if ml_rep>=4 && gain2>gain1 {
                            match_length=ml_rep
                            off_base=repcode_to_offbase(1)
                            start=ip
                        }
                    }
                    {
                        ofb_candidate:=ABSENT_OFF_BASE
                        ml2:=search_max(ms,ip,iend,&ofb_candidate,mls,row_log,method)
                        gain2:=ml2*4-int(highbit32(ofb_candidate))
                        gain1:=match_length*4-int(highbit32(off_base))+4
                        if ml2>=4 && gain2>gain1 {
                            match_length=ml2
                            off_base=ofb_candidate
                            start=ip
                            continue
                        }
                    }

                    if depth==2 && uintptr(ip)<uintptr(ilimit) {
                        ip=padd(ip,1)
                        if off_base!=0 && offset_1>0 && read32(ip)==read32(padd(ip,-int(offset_1))) {
                            ml_rep:=count(padd(ip,4),padd(ip,4-int(offset_1)),iend)+4
                            gain2:=ml_rep*4
                            gain1:=match_length*4-int(highbit32(off_base))+1
                            if ml_rep>=4 && gain2>gain1 {
                                match_length=ml_rep
                                off_base=repcode_to_offbase(1)
                                start=ip
                            }
                        }
                        {
                            ofb_candidate:=ABSENT_OFF_BASE
                            ml2:=search_max(ms,ip,iend,&ofb_candidate,mls,row_log,method)
                            gain2:=ml2*4-int(highbit32(ofb_candidate))
                            gain1:=match_length*4-int(highbit32(off_base))+7
                            if ml2>=4 && gain2>gain1 {
                                match_length=ml2
                                off_base=ofb_candidate
                                start=ip
                                continue
                            }
                        }
                    }
                    break
                }
            }

            if offbase_is_offset(off_base) {
                back:=int(offbase_to_offset(off_base))
                for uintptr(start)>uintptr(anchor) && uintptr(padd(start,-back))>uintptr(prefix_lowest) && padd(start,-1)[0]==padd(start,-back-1)[0] {
                    start=padd(start,-1)
                    match_length+=1
                }
                offset_2=offset_1
                offset_1=offbase_to_offset(off_base)
            }
        }

        {
            lit_length:=pdiff(start,anchor)
            store_seq(store,lit_length,anchor,iend,off_base,match_length)
            ip=padd(start,match_length)
            anchor=ip
        }
        if ms.lazy_skipping {
            if method==.Row_Hash {
                row_fill_hash_cache(ms,base,row_log,mls,ms.next_to_update,ilimit)
            }
            ms.lazy_skipping=false
        }

        for uintptr(ip)<=uintptr(ilimit) && offset_2>0 && read32(ip)==read32(padd(ip,-int(offset_2))) {
            match_length=count(padd(ip,4),padd(ip,4-int(offset_2)),iend)+4
            off_base=offset_2
            offset_2=offset_1
            offset_1=off_base
            store_seq(store,0,anchor,iend,repcode_to_offbase(1),match_length)
            ip=padd(ip,match_length)
            anchor=ip
        }
    }

    offset_saved2=(offset_saved1!=0 && offset_1!=0) ? offset_saved1 : offset_saved2

    rep[0]=offset_1!=0 ? offset_1 : offset_saved1
    rep[1]=offset_2!=0 ? offset_2 : offset_saved2

    return pdiff(iend,anchor)
}

compress_block_greedy :: proc "contextless" (ms:^Match_State,store:^Seq_Store,rep:^[REP_NUM]u32,src:[^]u8,src_size:int) -> int {
    return compress_block_lazy_generic(ms,store,rep,src,src_size,.Hash_Chain,0)
}

compress_block_greedy_row :: proc "contextless" (ms:^Match_State,store:^Seq_Store,rep:^[REP_NUM]u32,src:[^]u8,src_size:int) -> int {
    return compress_block_lazy_generic(ms,store,rep,src,src_size,.Row_Hash,0)
}

compress_block_lazy :: proc "contextless" (ms:^Match_State,store:^Seq_Store,rep:^[REP_NUM]u32,src:[^]u8,src_size:int) -> int {
    return compress_block_lazy_generic(ms,store,rep,src,src_size,.Hash_Chain,1)
}

compress_block_lazy_row :: proc "contextless" (ms:^Match_State,store:^Seq_Store,rep:^[REP_NUM]u32,src:[^]u8,src_size:int) -> int {
    return compress_block_lazy_generic(ms,store,rep,src,src_size,.Row_Hash,1)
}

compress_block_lazy2 :: proc "contextless" (ms:^Match_State,store:^Seq_Store,rep:^[REP_NUM]u32,src:[^]u8,src_size:int) -> int {
    return compress_block_lazy_generic(ms,store,rep,src,src_size,.Hash_Chain,2)
}

compress_block_lazy2_row :: proc "contextless" (ms:^Match_State,store:^Seq_Store,rep:^[REP_NUM]u32,src:[^]u8,src_size:int) -> int {
    return compress_block_lazy_generic(ms,store,rep,src,src_size,.Row_Hash,2)
}
