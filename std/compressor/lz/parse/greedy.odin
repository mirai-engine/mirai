package parse

import "base:intrinsics"
import "mirai:std/compressor/lz/entropy"
import "mirai:std/compressor/lz/match"
import "mirai:std/compressor"

// A chosen match: off > 0 is a normal offset, -i is last offset i.
Match :: struct {ml,off:i32}

is_lo :: #force_inline proc "contextless" (m:Match) -> bool {return m.off<=0}

is_allowed_normal_match_optimal :: #force_inline proc "contextless" (ml:i32,off:u32,
    o:^Options) -> bool {
    if o.far_match_offset_log2>0 && o.far_match_offset_log2<32 &&
        off>=(u32(1)<<u32(o.far_match_offset_log2)) {
        if ml<o.far_match_min_len {return false}
    }
    if off>=(1<<20) {
        if off>=(1<<22) {return ml>=8}
        if off>=(1<<21) {return ml>=6}
        return ml>=5
    }
    return true
}

is_allowed_normal_match :: #force_inline proc "contextless" (ml:i32,off:u32,o:^Options) -> bool {
    if !is_allowed_normal_match_optimal(ml,off,o) {return false}
    if ml>5 {return true}
    @(static,rodata) max_offset:=[6]u32{0,0,0,1<<14,1<<17,1<<20}
    if ml<0 {return false}
    return off<max_offset[ml]
}

is_normal_match_better :: #force_inline proc "contextless" (ml:i32,off:u32,bestml:i32,
    bestoff:u32) -> bool {
    if ml<bestml {return false}
    if ml==bestml {return off<bestoff}
    if ml>bestml+1 {return true}
    return (off>>7)<=bestoff
}

is_lo_match_better :: #force_inline proc "contextless" (rep_len,main_len:i32,
    main_dist:u32) -> bool {
    return rep_len>=2 && (rep_len+1>=main_len || (rep_len+2>=main_len && main_dist>=(1<<10)) ||
        (rep_len+3>=main_len && main_dist>=(1<<16)))
}

lazy_match_delta :: #force_inline proc "contextless" (new_ml:i32,new_off:i32,new_is_last:bool,
    old_ml:i32,old_off:i32,old_is_last:bool) -> i32 {
    if new_ml==0 {return 0}
    new_log2:=new_is_last ? 0 : 2+i32(entropy.bit_level(u32(new_off)))
    old_log2:=old_is_last ? 0 : 2+i32(entropy.bit_level(u32(old_off)))
    new_gain:=new_ml*4-new_log2
    old_gain:=(old_ml+1)*4-old_log2
    return new_gain-old_gain
}

@(private)
find_lo0_match_ahead :: #force_inline proc "contextless" (m:^Match, ctmf:^match.Ctmf($H,$D,$S,$MM),
    los:^LOs, ptr,ptr_matchend:[^]u8) -> bool {
    lo:=int(los.lasts[0])
    p1:=ptr[1:]
    if load32(p1)!=load32(padd(p1,-lo)) {return false}
    m.ml=i32(match.getmatchlen_after4(p1,padd(p1,-lo),ptr_matchend))
    m.off=0
    row:=ctmf.next_row
    h:=ctmf.next_hash
    row2:=ctmf.next_row_second
    match.ctmf_prefetch_next(ctmf,ptr[2:])
    pos:=u32(pdiff(ptr,ctmf.base_ptr))
    match.ctmf_insert(ctmf,row,pos,h)
    when S>0 {match.ctmf_insert(ctmf,row2,pos,h)}
    return true
}

@(private)
get_match_heuristic :: proc "contextless" (m:^Match, ctmf:^match.Ctmf($H,$D,$S,$MM), step:int,
    los:^LOs,
    ptr,ptr_matchend:[^]u8, mml_in:int, literals_start:[^]u8, dictionary_size:u32, lo0_allowed:bool,
    o:^Options) -> bool #no_bounds_check {
    mml:=mml_in
    ptr32:=load32(ptr)
    row:=ctmf.next_row
    h:=ctmf.next_hash
    row2:=ctmf.next_row_second
    cur_pos:=u32(pdiff(ptr,ctmf.base_ptr))
    match.ctmf_prefetch_next(ctmf,ptr[step:])

    lo_index:=-1
    lo_ml:=0
    for i in 0..<compressor.LZ_NUM_LAST_OFFSETS {
        if i!=0 || lo0_allowed {
            offset:=int(los.lasts[i])
            ml:int
            if match.havematch_mml2_one32(ptr32,ptr,padd(ptr,-offset),ptr_matchend,&ml) {
                if i==0 || ml>lo_ml {lo_ml=ml;lo_index=i}
            }
        }
    }
    if lo_ml>=LOML_GOOD_ENOUGH {
        m.ml=i32(lo_ml);m.off=-i32(lo_index)
        match.ctmf_insert(ctmf,row,cur_pos,h)
        when S>0 {match.ctmf_insert(ctmf,row2,cur_pos,h)}
        return true
    }
    if pdiff(ptr,literals_start)>=LRL_FOR_LONGER_MML {
        if lo_ml<=2 {lo_ml=0}
        if mml<5 {mml=5}
    }
    bestml:i32
    bestoff:u32
    candidates:[(1<<uint(D))*2]u32
    mask:=match.ctmf_find_candidates(ctmf,raw_data(candidates[:]),row,row2,cur_pos,h)
    prevml:=mml-1
    for mask!=0 {
        i:=intrinsics.count_trailing_zeros(mask)
        mask&=mask-1
        offset:=candidates[i]
        if offset>=dictionary_size {continue}
        if offset<compressor.MIN_OFFSET {offset=compressor.MIN_OFFSET}
        // only chunks encoded out of order can leave entries past cur_pos
        if offset>cur_pos {continue}
        l:int
        if !match.havematch_better(ptr,padd(ptr,-int(offset)),ptr_matchend,prevml,&l) {continue}
        prevml=l
        l32:=i32(l)
        if is_allowed_normal_match(l32,offset,o) && is_normal_match_better(l32,offset,bestml,
            bestoff) {
            bestml=l32;bestoff=offset
        }
    }
    match.ctmf_insert(ctmf,row,cur_pos,h)
    when S>0 {match.ctmf_insert(ctmf,row2,cur_pos,h)}
    if !lo0_allowed && bestoff==u32(los.lasts[0]) {
        m.ml=bestml;m.off=0
        return true
    }
    if bestoff==0 {
        if lo_ml>=compressor.LZ_LOMML {m.ml=i32(lo_ml);m.off=-i32(lo_index);return true}
        return false
    }
    if is_lo_match_better(i32(lo_ml),bestml,bestoff) {
        m.ml=i32(lo_ml);m.off=-i32(lo_index)
    } else {
        m.ml=bestml;m.off=i32(bestoff)
    }
    return true
}

// newLZ_encode_chunk: greedy/lazy parse over a CTMF. LAZY 0, 1 or 2; STEP_SHIFT steps faster
// through literal runs (only without lazy).
@(private)
encode_chunk_lazy :: proc(c:^Chunk, ctmf:^match.Ctmf($H,$D,$S,$MM), $LAZY:int, $BACKUP:bool,
    $STEP_SHIFT:uint, pchunktype:^i32, pJ:^f32) -> int {
    pchunktype^=-1
    chunk_len:=c.chunk_len
    if chunk_len<=compressor.MIN_CHUNK_LEN {return chunk_len}
    e:=c.e
    o:=&e.options
    dict_size:=dictionary_size(o)
    mml:=int(max(o.min_match_len,MML_NORMAL))
    chunk_ptr:=c.chunk_ptr
    ea:Encoder_Arrays
    arrays_point_to_scratch(&ea,raw_data(e.arrays_space),chunk_len,chunk_ptr,e.bitstream_flags)
    ptr_matchend:=chunk_ptr[chunk_len-compressor.LZ_MATCH_END_PAD:]
    parse_end_pos:=chunk_len-compressor.LZ_NO_MATCH_ZONE
    los:LOs
    los_reset(&los)
    start_pos:=c.chunk_pos==0 ? compressor.MIN_OFFSET : 0
    start_ptr:=chunk_ptr[start_pos:]
    literals_start:=start_ptr
    match.ctmf_set_next(ctmf,start_ptr)
    parse_end_ptr:=chunk_ptr[parse_end_pos:]

    ptr:=start_ptr
    parse_loop: for {
        chosen:Match
        scaled_skip_dist:=u32(1)<<STEP_SHIFT
        for {
            when LAZY==0 {
                if find_lo0_match_ahead(&chosen,ctmf,&los,ptr,ptr_matchend) {
                    ptr=ptr[1:]
                    break
                }
            }
            step:=STEP_SHIFT>0 ? int(scaled_skip_dist>>STEP_SHIFT) : 1
            if pdiff(parse_end_ptr,ptr)<=step {break parse_loop}
            if get_match_heuristic(&chosen,ctmf,step,&los,ptr,ptr_matchend,mml,literals_start,
                dict_size,true,o) {
                break
            }
            when STEP_SHIFT>0 {scaled_skip_dist+=1}
            ptr=ptr[step:]
        }
        when LAZY>0 {
            for uintptr(ptr[1:])<uintptr(parse_end_ptr) {
                lazy:Match
                if get_match_heuristic(&lazy,ctmf,1,&los,ptr[1:],ptr_matchend,mml,literals_start,
                    dict_size,true,o) &&
                    lazy_match_delta(lazy.ml,lazy.off,is_lo(lazy),chosen.ml,chosen.off,
                        is_lo(chosen))>0 {
                    ptr=ptr[1:]
                    chosen=lazy
                    continue
                }
                when LAZY>=2 {
                    if uintptr(ptr[2:])>=uintptr(parse_end_ptr) {break}
                    if chosen.ml==2 {break}
                    if get_match_heuristic(&lazy,ctmf,1,&los,ptr[2:],ptr_matchend,mml,
                        literals_start,dict_size,true,o) &&
                        lazy_match_delta(lazy.ml,lazy.off,is_lo(lazy),chosen.ml,chosen.off,
                            is_lo(chosen))>LAZYBETTER_LAZY2 {
                        ptr=ptr[2:]
                        chosen=lazy
                    } else {
                        break
                    }
                } else {
                    break
                }
            }
        }
        offset:=is_lo(chosen) ? int(los.lasts[-chosen.off]) : int(chosen.off)
        when BACKUP {
            for uintptr(ptr)>uintptr(literals_start) {
                if pdiff(ptr,ctmf.base_ptr)<=offset {break}
                if ptr[-1]==padd(ptr,-1-offset)[0] {
                    ptr=padd(ptr,-1)
                    chosen.ml+=1
                } else {
                    break
                }
            }
        }
        if chosen.off==0 && ptr==literals_start {chosen.off=-1}
        lrl:=pdiff(ptr,literals_start)
        arrays_put_packet(&ea,&los,lrl,int(chosen.ml),int(chosen.off),literals_start,false,true)
        ptr=ptr[chosen.ml:]
        literals_start=ptr
        if uintptr(ptr)>=uintptr(parse_end_ptr) {break}
        match.ctmf_step_and_insert(ctmf,padd(ptr,-int(chosen.ml)),int(chosen.ml))
    }
    arrays_finish_chunk(&ea,literals_start,true)
    return arrays_output(c,pJ,pchunktype,nil,c.comp,c.comp_end,&ea,e.level,e.entropy_flags)
}

@(private)
different_bytes1to3le :: #force_inline proc "contextless" (a,b:u32) -> u32 {return (a~b)>>8}

// newLZ_encode_chunk_fast_mode: single-way hash, rep offset 0 only (plus 1 and 2 with LO12).
@(private)
encode_chunk_fast_mode :: proc(c:^Chunk, ctmf:^match.Fast_Ctmf($H), $STEP_SHIFT:uint, $BACKUP:bool,
    $QUADRATIC_SKIP:uint, $SUB_LITS:bool, $LO12:bool, pchunktype:^i32,
        pJ:^f32) -> int #no_bounds_check {
    pchunktype^=-1
    chunk_len:=c.chunk_len
    if chunk_len<=compressor.MIN_CHUNK_LEN {return chunk_len}
    e:=c.e
    dict_size:=dictionary_size(&e.options)
    if dict_size<compressor.MIN_OFFSET {return chunk_len}
    dictionary_span:=dict_size-compressor.MIN_OFFSET
    chunk_ptr:=c.chunk_ptr
    ea:Encoder_Arrays
    arrays_point_to_scratch(&ea,raw_data(e.arrays_space),chunk_len,chunk_ptr,e.bitstream_flags)
    los:LOs
    los_reset(&los)
    ptr_matchend:=chunk_ptr[chunk_len-compressor.LZ_MATCH_END_PAD:]
    parse_end_pos:=chunk_len-compressor.LZ_NO_MATCH_ZONE
    start_pos:=c.chunk_pos==0 ? compressor.MIN_OFFSET : 0
    neg_lo0:=-compressor.MIN_OFFSET
    start_ptr:=chunk_ptr[start_pos:]
    parse_end_ptr:=chunk_ptr[parse_end_pos:]
    literals_start:=start_ptr
    hash_base:=ctmf.base_ptr
    hash_table:=raw_data(ctmf.hash_table)
    hash_mul:=ctmf.hash_mul
    hash_shift:=ctmf.hash_shift

    ptr:=start_ptr
    parse_loop: for {
        match_start:[^]u8
        neg_offs:int
        code_offs:i32
        scaled_skip_dist:=1<<STEP_SHIFT
        got: {
            for {
                step:=scaled_skip_dist>>STEP_SHIFT
                if pdiff(parse_end_ptr,ptr)<=step {break parse_loop}
                ptr64:=load64(ptr)
                ptr32:=u32(ptr64)
                pos:=pdiff(ptr,hash_base)
                hashpos:=match.fast_ctmf_insert(hash_table,ptr64,hash_mul,hash_shift,pos)
                when LO12 {
                    p16:=u16(ptr64)
                    if p16==load16(padd(ptr,-int(los.lasts[1]))) {
                        code_offs=-1;match_start=ptr;neg_offs=-int(los.lasts[1])
                        ptr=ptr[2:]
                        break got
                    } else if p16==load16(padd(ptr,-int(los.lasts[2]))) {
                        code_offs=-2;match_start=ptr;neg_offs=-int(los.lasts[2])
                        ptr=ptr[2:]
                        break got
                    }
                }
                if different_bytes1to3le(ptr32,load32(padd(ptr,neg_lo0)))==0 {
                    ptr=ptr[1:]
                    neg_offs=neg_lo0
                    code_offs=0
                    match.fast_ctmf_insert(hash_table,ptr,hash_mul,hash_shift,pos+1)
                    match_start=ptr
                    ptr=ptr[3:]
                    break got
                }
                code_offs=i32(H(H(pos)-hashpos))
                // only chunks encoded out of order can leave entries past pos
                if code_offs>=0 && int(code_offs)<=pos {
                    match32:=load32(padd(ptr,-int(code_offs)))
                    if match32==ptr32 {
                        if u32(code_offs-compressor.MIN_OFFSET)<dictionary_span {
                            neg_offs=-int(code_offs)
                            break
                        } else if ptr32==load32(padd(ptr,-compressor.MIN_OFFSET)) {
                            code_offs=compressor.MIN_OFFSET
                            neg_offs=-compressor.MIN_OFFSET
                            break
                        }
                    }
                }
                when QUADRATIC_SKIP>0 {
                    scaled_skip_dist+=pdiff(ptr,literals_start)>>QUADRATIC_SKIP
                    scaled_skip_dist=min(scaled_skip_dist,37<<STEP_SHIFT)
                } else {
                    scaled_skip_dist+=1
                }
                ptr=ptr[step:]
            }
            when BACKUP {
                for uintptr(ptr)>uintptr(literals_start) {
                    if pdiff(hash_base,ptr)>=neg_offs || ptr[-1]!=padd(ptr,neg_offs-1)[0] {break}
                    ptr=padd(ptr,-1)
                }
                if ptr==literals_start && code_offs==0 {code_offs=i32(-neg_lo0)}
            }
            match_start=ptr
            ptr=ptr[4:]
        }
        for uintptr(ptr)<uintptr(ptr_matchend) {
            big1:=load64(ptr)
            big2:=load64(padd(ptr,neg_offs))
            ptr=ptr[8:]
            if big1!=big2 {
                ptr=padd(ptr,-8)
                ptr=padd(ptr,int(intrinsics.count_trailing_zeros(big1~big2)>>3))
                break
            }
        }
        if uintptr(ptr)>uintptr(ptr_matchend) {ptr=ptr_matchend}
        lrl:=pdiff(match_start,literals_start)
        ml:=pdiff(ptr,match_start)
        arrays_put_packet(&ea,&los,lrl,ml,int(code_offs),literals_start,!LO12,SUB_LITS)
        literals_start=ptr
        neg_lo0=neg_offs
        if uintptr(ptr)>=uintptr(parse_end_ptr) {break}
        when LO12 {
            base_pos:=pdiff(match_start,hash_base)
            for i:=1;i<ml;i+=i {
                match.fast_ctmf_insert(hash_table,padd(match_start,i),hash_mul,hash_shift,
                    base_pos+i)
            }
        }
    }
    arrays_finish_chunk(&ea,literals_start,SUB_LITS)
    return arrays_output(c,pJ,pchunktype,nil,c.comp,c.comp_end,&ea,e.level,e.entropy_flags)
}
