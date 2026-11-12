package zstd

import "base:intrinsics"

@(private="file") DFAST_STEP_INCR :: 1<<8

@(private="file") Dfast_Outcome :: enum {Cleanup,Search_Next_Long,Match_Found,Match_Stored}

@(private="file")
double_fast_no_dict :: #force_inline proc "contextless" (ms:^Match_State,store:^Seq_Store,rep:^[REP_NUM]u32,src:[^]u8,src_size:int,mls:u32) -> int #no_bounds_check {
    c_params:=&ms.c_params
    hash_long:=ms.hash_table
    h_bits_l:=c_params.hash_log
    hash_small:=ms.chain_table
    h_bits_s:=c_params.chain_log
    base:=ms.window.base
    istart:=src
    anchor:=istart
    end_index:=u32(pdiff(istart,base)+src_size)
    prefix_lowest_index:=get_lowest_prefix_index(ms,end_index,c_params.window_log)
    prefix_lowest:=padd(base,int(prefix_lowest_index))
    iend:=padd(istart,src_size)
    ilimit:=padd(iend,-HASH_READ_SIZE)
    offset_1,offset_2:=rep[0],rep[1]
    offset_saved1,offset_saved2:u32=0,0

    m_length:int
    offset,curr:u32
    next_step:[^]u8
    step:int
    hl0,hl1:int
    idxl0,idxl1:u32
    matchl0,matchs0,matchl1,matchs0_safe:[^]u8
    ip:=istart
    ip1:[^]u8
    // Compared in place of a table entry that is out of the window, to avoid a branch on it.
    dummy:=[10]u8{0x12,0x34,0x56,0x78,0x9a,0xbc,0xde,0xf0,0xe2,0xb4}
    dummy_at:=([^]u8)(&dummy)

    if pdiff(ip,prefix_lowest)==0 {ip=padd(ip,1)}
    {
        current:=u32(pdiff(ip,base))
        window_low:=get_lowest_prefix_index(ms,current,c_params.window_log)
        max_rep:=current-window_low
        if offset_2>max_rep {offset_saved2=offset_2;offset_2=0}
        if offset_1>max_rep {offset_saved1=offset_1;offset_1=0}
    }

    for {
        step=1
        next_step=padd(ip,DFAST_STEP_INCR)
        ip1=padd(ip,step)
        outcome:=Dfast_Outcome.Cleanup

        if uintptr(ip1)<=uintptr(ilimit) {
            hl0=hash_ptr(ip,h_bits_l,8)
            idxl0=hash_long[hl0]
            matchl0=padd(base,int(idxl0))

            search: for {
                hs0:=hash_ptr(ip,h_bits_s,mls)
                idxs0:=hash_small[hs0]
                curr=u32(pdiff(ip,base))
                matchs0=padd(base,int(idxs0))

                hash_small[hs0]=curr
                hash_long[hl0]=curr

                if offset_1>0 && read32(padd(ip,1-int(offset_1)))==read32(padd(ip,1)) {
                    m_length=count(padd(ip,1+4),padd(ip,1+4-int(offset_1)),iend)+4
                    ip=padd(ip,1)
                    store_seq(store,pdiff(ip,anchor),anchor,iend,repcode_to_offbase(1),m_length)
                    outcome=.Match_Stored
                    break search
                }

                hl1=hash_ptr(ip1,h_bits_l,8)

                matchl0_safe:=select_addr(idxl0,prefix_lowest_index,matchl0,dummy_at)
                if read64(matchl0_safe)==read64(ip) && uintptr(matchl0_safe)==uintptr(matchl0) {
                    m_length=count(padd(ip,8),padd(matchl0,8),iend)+8
                    offset=u32(pdiff(ip,matchl0))
                    for uintptr(ip)>uintptr(anchor) && uintptr(matchl0)>uintptr(prefix_lowest) && padd(ip,-1)[0]==padd(matchl0,-1)[0] {
                        ip=padd(ip,-1)
                        matchl0=padd(matchl0,-1)
                        m_length+=1
                    }
                    outcome=.Match_Found
                    break search
                }

                idxl1=hash_long[hl1]
                matchl1=padd(base,int(idxl1))

                matchs0_safe=select_addr(idxs0,prefix_lowest_index,matchs0,dummy_at)
                if read32(matchs0_safe)==read32(ip) && uintptr(matchs0_safe)==uintptr(matchs0) {
                    outcome=.Search_Next_Long
                    break search
                }

                if uintptr(ip1)>=uintptr(next_step) {
                    intrinsics.prefetch_read_data(padd(ip1,64),3)
                    intrinsics.prefetch_read_data(padd(ip1,128),3)
                    step+=1
                    next_step=padd(next_step,DFAST_STEP_INCR)
                }
                ip=ip1
                ip1=padd(ip1,step)

                hl0=hl1
                idxl0=idxl1
                matchl0=matchl1

                if uintptr(ip1)>uintptr(ilimit) {break search}
            }
        }

        if outcome==.Cleanup {
            offset_saved2=(offset_saved1!=0 && offset_1!=0) ? offset_saved1 : offset_saved2
            rep[0]=offset_1!=0 ? offset_1 : offset_saved1
            rep[1]=offset_2!=0 ? offset_2 : offset_saved2
            return pdiff(iend,anchor)
        }

        if outcome==.Search_Next_Long {
            m_length=count(padd(ip,4),padd(matchs0,4),iend)+4
            offset=u32(pdiff(ip,matchs0))

            if idxl1>prefix_lowest_index && read64(matchl1)==read64(ip1) {
                l1len:=count(padd(ip1,8),padd(matchl1,8),iend)+8
                if l1len>m_length {
                    ip=ip1
                    m_length=l1len
                    offset=u32(pdiff(ip,matchl1))
                    matchs0=matchl1
                }
            }

            for uintptr(ip)>uintptr(anchor) && uintptr(matchs0)>uintptr(prefix_lowest) && padd(ip,-1)[0]==padd(matchs0,-1)[0] {
                ip=padd(ip,-1)
                matchs0=padd(matchs0,-1)
                m_length+=1
            }
        }

        if outcome!=.Match_Stored {
            offset_2=offset_1
            offset_1=offset

            // Past ip + 4 the position written here could be inside the match.
            if step<4 {hash_long[hl1]=u32(pdiff(ip1,base))}

            store_seq(store,pdiff(ip,anchor),anchor,iend,offset_to_offbase(offset),m_length)
        }

        ip=padd(ip,m_length)
        anchor=ip

        if uintptr(ip)<=uintptr(ilimit) {
            index_to_insert:=curr+2
            hash_long[hash_ptr(padd(base,int(index_to_insert)),h_bits_l,8)]=index_to_insert
            hash_long[hash_ptr(padd(ip,-2),h_bits_l,8)]=u32(pdiff(padd(ip,-2),base))
            hash_small[hash_ptr(padd(base,int(index_to_insert)),h_bits_s,mls)]=index_to_insert
            hash_small[hash_ptr(padd(ip,-1),h_bits_s,mls)]=u32(pdiff(padd(ip,-1),base))

            for uintptr(ip)<=uintptr(ilimit) && offset_2>0 && read32(ip)==read32(padd(ip,-int(offset_2))) {
                r_length:=count(padd(ip,4),padd(ip,4-int(offset_2)),iend)+4
                tmp_off:=offset_2
                offset_2=offset_1
                offset_1=tmp_off
                hash_small[hash_ptr(ip,h_bits_s,mls)]=u32(pdiff(ip,base))
                hash_long[hash_ptr(ip,h_bits_l,8)]=u32(pdiff(ip,base))
                store_seq(store,0,anchor,iend,repcode_to_offbase(1),r_length)
                ip=padd(ip,r_length)
                anchor=ip
            }
        }
    }
}

compress_block_double_fast :: proc "contextless" (ms:^Match_State,store:^Seq_Store,rep:^[REP_NUM]u32,src:[^]u8,src_size:int) -> int {
    switch ms.c_params.min_match {
    case 5: return double_fast_no_dict(ms,store,rep,src,src_size,5)
    case 6: return double_fast_no_dict(ms,store,rep,src,src_size,6)
    case 7: return double_fast_no_dict(ms,store,rep,src,src_size,7)
    case: return double_fast_no_dict(ms,store,rep,src,src_size,4)
    }
}
