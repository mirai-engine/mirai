package lz_optimal

import "base:runtime"
import "mirai:std/compressor/lz/entropy"
import "mirai:std/compressor/lz/match"
import "mirai:std/compressor"
import "mirai:std/compressor/lz/parse"

// Optimal parse (Optimal1-5): a greedy/lazy seed parse over the found matches gives the starting
// statistics, then a forward arrival parse in pieces of ~256 bytes re-costs with the running
// histograms. num_tlls 2 (Optimal4+) keeps arrivals carrying 1 or more trailing literals.

@(private) COST_PENALTY_SCALE :: 6
@(private) COST_PENALTY_PACKET :: 3*COST_PENALTY_SCALE
@(private) COST_PENALTY_EXCESS :: 2*COST_PENALTY_SCALE
@(private) COST_PENALTY_NORMAL_MATCH :: 6*COST_PENALTY_SCALE
@(private) SHORTCOST_COUNT :: 32
@(private) SHORT_ENDML :: compressor.LZ_LOMML+SHORTCOST_COUNT
@(private) TWO_STEP_MAX_LRL :: 3
@(private) FINAL_EXTRA_BACKUP :: 8
@(private) S32_MAX :: max(i32)

Match_Parse_Record :: struct {pairs:[match.NEWLZ_MATCH_NUM_PAIRS]match.Unpacked_Match_Pair}

@(private)
LOs_NoPad :: struct {lasts:[3]i32}

@(private)
nopad_set_mtf :: #force_inline proc "contextless" (to:^LOs_NoPad,from:^LOs_NoPad,index:int) {
    f:=from^
    switch index {
    case 0: to^=f
    case 1: to.lasts={f.lasts[1],f.lasts[0],f.lasts[2]}
    case: to.lasts={f.lasts[2],f.lasts[0],f.lasts[1]}
    }
}

@(private)
nopad_set_add :: #force_inline proc "contextless" (to:^LOs_NoPad,from:^LOs_NoPad,offset:i32) {
    f:=from^
    to.lasts={offset,f.lasts[0],f.lasts[1]}
}

@(private)
nopad_find :: #force_inline proc "contextless" (l:^LOs_NoPad,offset:i32) -> int {
    for i in 0..<3 {if offset==l.lasts[i] {return i}}
    return -1
}

@(private)
Arrival :: struct {
    los:LOs_NoPad, // the set after this arrival's packet; los[0] is the offset it used
    ml,lrl:i32,
    twostep:u32, // 0, or lrl in bits 0-7 and ml in bits 8-31 of a following rep0 match
    prev_index:i32,
}

@(private)
Arrivals :: struct {cost:[^]i32, a:[^]Arrival}

@(private)
arrivals_size :: proc "contextless" (count:int) -> int {
    return count*(size_of(i32)+size_of(Arrival))
}

@(private)
Codecosts :: struct {
    chunktype:i32,
    subliteralmask:u32,
    codecost_literal:[256]i32,
    codecost_packet:[256]i32,
    offset_alt_modulo:int,
    codecost_offset1:[256]i32,
    codecost_offset2:[256]i32,
    codecost_excess:[256]i32,
    cost_packet_short:[4][4][SHORTCOST_COUNT]i32, // [packet_lrl][loi][ml - compressor.LZ_LOMML]
}

@(private)
cost_literals :: #force_inline proc "contextless" (chunk:[^]u8, pos:int, lrl:int, lo:i32,
    cc:^Codecosts) -> i32 #no_bounds_check {
    ret:i32
    p:=pos
    for _ in 0..<lrl {
        sub:=chunk[p]-(padd(chunk,p-int(lo))[0]&u8(cc.subliteralmask))
        ret+=cc.codecost_literal[sub]
        p+=1
    }
    return ret
}

@(private)
cost_add_literal :: #force_inline proc "contextless" (chunk:[^]u8, pos:int, lo:i32,
    cc:^Codecosts) -> i32 #no_bounds_check {
    sub:=chunk[pos]-(padd(chunk,pos-int(lo))[0]&u8(cc.subliteralmask))
    return cc.codecost_literal[sub]
}

@(private)
cost_excess :: #force_inline proc "contextless" (excess:int,
    cc:^Codecosts) -> i32 #no_bounds_check {
    if excess<255 {return cc.codecost_excess[excess]}
    ret:=cc.codecost_excess[255]
    bits:=entropy.count_bits_exp_golomb(u32(excess-255),compressor.EXCESS_EXPGOLOMB_SHIFT)
    return ret+i32(entropy.COST_ONE_BIT*bits)
}

@(private)
cost_lo_match :: #force_inline proc "contextless" (lrl_for_packet,ml,loi:int,
    cc:^Codecosts) -> i32 #no_bounds_check {
    ml_excess:=ml-(compressor.LZ_LOMML+compressor.LZ_ML_MAX)
    if ml_excess<0 {
        return cc.codecost_packet[lrl_for_packet+(ml<<2)-(compressor.LZ_LOMML<<2)+(loi<<6)]
    }
    return cc.codecost_packet[lrl_for_packet+(compressor.LZ_ML_MAX<<2)+(loi<<6)]+
        cost_excess(ml_excess,cc)
}

@(private)
cost_offset :: #force_inline proc "contextless" (offset:u32,
    cc:^Codecosts) -> i32 #no_bounds_check {
    cost:i32
    if cc.offset_alt_modulo==0 {
        c:=parse.offset44_pack_u8(i32(offset))
        cost+=cc.codecost_offset1[c]
        cost+=i32(parse.offset44_unpack_numrawbits(c))*entropy.COST_ONE_BIT
        if offset>=parse.ESCAPE_OFFSET_MIN {cost+=COST_PENALTY_EXCESS}
    } else if cc.offset_alt_modulo==1 {
        c:=parse.alt_offset_pack_u8_modulo1(offset)
        cost+=cc.codecost_offset1[c]
        cost+=i32(parse.alt_offset_unpack_numrawbits(c))*entropy.COST_ONE_BIT
    } else {
        top,bot:=parse.alt_offset_pack_u8s(offset,u32(cc.offset_alt_modulo))
        cost+=cc.codecost_offset1[top]
        cost+=cc.codecost_offset2[bot]
        cost+=i32(parse.alt_offset_unpack_numrawbits(top))*entropy.COST_ONE_BIT
    }
    return cost
}

@(private)
cost_normal_match :: #force_inline proc "contextless" (lrl_for_packet,ml:int,
    cc:^Codecosts) -> i32 #no_bounds_check {
    ml_excess:=ml-(compressor.LZ_LOMML+compressor.LZ_ML_MAX)
    if ml_excess<0 {
        return cc.codecost_packet[lrl_for_packet+(ml<<2)-(compressor.LZ_LOMML<<2)+(3<<6)]
    }
    return cc.codecost_packet[lrl_for_packet+(compressor.LZ_ML_MAX<<2)+(3<<6)]+
        cost_excess(ml_excess,cc)
}

@(private)
arrival_set_lo :: #force_inline proc "contextless" (a:^Arrival,prev_index:int,lrl,ml,loi:int,
    los:^LOs_NoPad) {
    a.ml=i32(ml);a.lrl=i32(lrl)
    nopad_set_mtf(&a.los,los,loi)
    a.twostep=0
    a.prev_index=i32(prev_index)
}

@(private)
arrival_set_match :: #force_inline proc "contextless" (a:^Arrival,prev_index:int,lrl,ml:int,
    offset:u32,los:^LOs_NoPad) {
    a.ml=i32(ml);a.lrl=i32(lrl)
    nopad_set_add(&a.los,los,i32(offset))
    a.twostep=0
    a.prev_index=i32(prev_index)
}

@(private)
try_lo_arrival_tll :: #force_inline proc "contextless" (arr:^Arrivals, $NUM_TLLS:int,
    prev_index:int,
    chunk_ptr:[^]u8, last_tll_len:[^]i32, pos:int, base_cost:i32, lrl,lrl_for_packet,ml,loi:int,
    los:^LOs_NoPad, cc:^Codecosts) -> i32 #no_bounds_check {
    lo_cost:=base_cost+cost_lo_match(lrl_for_packet,ml,loi,cc)
    when NUM_TLLS==1 {
        if lo_cost<arr.cost[pos+ml] {
            arr.cost[pos+ml]=lo_cost
            arrival_set_lo(&arr.a[pos+ml],prev_index,lrl,ml,loi,los)
        }
    } else {
        i0:=(pos+ml)*NUM_TLLS
        if lo_cost<arr.cost[i0] {
            arr.cost[i0]=lo_cost
            arrival_set_lo(&arr.a[i0],prev_index,lrl,ml,loi,los)
        }
        offset:=los.lasts[loi]
        cost:=lo_cost
        for t in 1..<NUM_TLLS {
            cost+=cost_add_literal(chunk_ptr,pos+ml+t-1,offset,cc)
            ap:=pos+ml+t
            ai:=ap*NUM_TLLS+t
            if cost<arr.cost[ai] {
                arr.cost[ai]=cost
                arrival_set_lo(&arr.a[ai],prev_index,lrl,ml,loi,los)
                if t==NUM_TLLS-1 {last_tll_len[ap]=i32(t)}
            }
        }
    }
    return lo_cost
}

@(private)
try_match_arrival_tll :: #force_inline proc "contextless" (arr:^Arrivals, $NUM_TLLS:int,
    prev_index:int,
    chunk_ptr:[^]u8, last_tll_len:[^]i32, pos:int, base_cost:i32, lrl,lrl_for_packet,ml:int,
        offset:u32,
    los:^LOs_NoPad, cc:^Codecosts) -> i32 #no_bounds_check {
    match_cost:=base_cost+cost_normal_match(lrl_for_packet,ml,cc)
    when NUM_TLLS==1 {
        if match_cost<arr.cost[pos+ml] {
            arr.cost[pos+ml]=match_cost
            arrival_set_match(&arr.a[pos+ml],prev_index,lrl,ml,offset,los)
        }
    } else {
        i0:=(pos+ml)*NUM_TLLS
        if match_cost<arr.cost[i0] {
            arr.cost[i0]=match_cost
            arrival_set_match(&arr.a[i0],prev_index,lrl,ml,offset,los)
        }
        cost:=match_cost
        for t in 1..<NUM_TLLS {
            cost+=cost_add_literal(chunk_ptr,pos+ml+t-1,i32(offset),cc)
            ai:=(pos+ml+t)*NUM_TLLS+t
            if cost<arr.cost[ai] {
                arr.cost[ai]=cost
                arrival_set_match(&arr.a[ai],prev_index,lrl,ml,offset,los)
                if t==NUM_TLLS-1 {last_tll_len[pos+ml+t]=i32(NUM_TLLS-1)}
            }
        }
    }
    return match_cost
}

// Two-step arrival: the first match ends at pos, then up to TWO_STEP_MAX_LRL literals and a rep0
// match resuming it.
@(private)
try_two_step_arrival_tll :: #force_inline proc "contextless" (arr:^Arrivals, $NUM_TLLS:int,
    prev_index:int,
    chunk_ptr,ptr_matchend:[^]u8, pparse_chunk_end:^int, pos:int, first_step_cost:i32,
    initial_ml,initial_lrl,initial_loi:int, offset:i32, los:^LOs_NoPad,
        cc:^Codecosts) #no_bounds_check {
    tp:=chunk_ptr[pos+TWO_STEP_MAX_LRL:]
    off:=int(offset)
    twostep_ml:=match.getmatchlen_mml1(tp,padd(tp,-off),ptr_matchend)
    twostep_lrl:=TWO_STEP_MAX_LRL
    adjust:=padd(tp,-2)[0]==padd(tp,-off-2)[0] ? 2 : 1
    adjust=padd(tp,-1)[0]==padd(tp,-off-1)[0] ? adjust : 0
    twostep_lrl-=adjust
    twostep_ml+=adjust
    if twostep_ml>=compressor.LZ_LOMML {
        lit_cost:=cost_literals(chunk_ptr,pos,twostep_lrl,offset,cc)
        cost:=first_step_cost+lit_cost
        lrl_fp:=twostep_lrl
        if twostep_lrl>=compressor.LZ_LRL_MAX {
            lrl_fp=compressor.LZ_LRL_MAX
            cost+=cost_excess(twostep_lrl-compressor.LZ_LRL_MAX,cc)
        }
        cost+=cost_lo_match(lrl_fp,twostep_ml,0,cc)
        ap:=pos+twostep_lrl+twostep_ml
        pparse_chunk_end^=max(pparse_chunk_end^,ap)
        ai:=ap*NUM_TLLS
        if cost<arr.cost[ai] {
            arr.cost[ai]=cost
            a:=&arr.a[ai]
            a.ml=i32(initial_ml)
            a.lrl=i32(initial_lrl)
            if initial_loi>=0 {nopad_set_mtf(&a.los,los,initial_loi)} else {nopad_set_add(&a.los,
                los,offset)}
            a.twostep=u32(twostep_lrl)|(u32(twostep_ml)<<8)
            a.prev_index=i32(prev_index)
        }
    }
}

// The seed heuristic over the found matches: same rules as the CTMF heuristic.
@(private)
get_match_heuristic_pairs :: proc "contextless" (rec:^Match_Parse_Record, los:^parse.LOs, ptr,
    ptr_matchend:[^]u8,
    mml_in:int, lrl:int, dictionary_base:[^]u8, dictionary_size:u32,
        o:^parse.Options) -> parse.Match #no_bounds_check {
    mml:=mml_in
    ptr32:=load32(ptr)
    lo_index:=-1
    lo_ml:=0
    for i in 0..<compressor.LZ_NUM_LAST_OFFSETS {
        offset:=int(los.lasts[i])
        ml:int
        if match.havematch_mml2_one32(ptr32,ptr,padd(ptr,-offset),ptr_matchend,&ml) {
            if i==0 || ml>lo_ml {lo_ml=ml;lo_index=i}
        }
    }
    if lo_ml>=parse.LOML_GOOD_ENOUGH {return parse.Match{i32(lo_ml),-i32(lo_index)}}
    if lrl>=parse.LRL_FOR_LONGER_MML {
        if lo_ml<=2 {lo_ml=0}
        mml+=1
    }
    bestml:i32
    bestoff:u32
    avail:=pdiff(ptr,dictionary_base)
    for m in 0..<match.NEWLZ_MATCH_NUM_PAIRS {
        l:=int(rec.pairs[m].length)
        if l<mml {break}
        if l>pdiff(ptr_matchend,ptr) {
            l=pdiff(ptr_matchend,ptr)
            if l<mml {break}
        }
        offset:=u32(rec.pairs[m].offset)
        if offset>=dictionary_size {continue}
        if offset<compressor.MIN_OFFSET {
            offset=round_up_small_offset(offset)
            if int(offset)>avail {continue}
            l=match.getmatchlen_mml3_one32(ptr32,ptr,padd(ptr,-int(offset)),ptr_matchend)
            if l<mml {continue}
        } else if int(offset)>avail {continue}
        l32:=i32(l)
        if parse.is_allowed_normal_match(l32,offset,o) && parse.is_normal_match_better(l32,offset,bestml,
            bestoff) {
            bestml=l32;bestoff=offset
        }
    }
    if parse.is_lo_match_better(i32(lo_ml),bestml,bestoff) {return parse.Match{i32(lo_ml),-i32(lo_index)}}
    return parse.Match{bestml,i32(bestoff)}
}

// The greedy/lazy2 seed parse of the optimal levels, output as Normal without splits.
@(private)
encode_chunk_optimal_greedy :: proc(c:^parse.Chunk, pJ:^f32, pchunktype:^i32, passinfo:^parse.Passinfo,
    comp,comp_end:[^]u8, mml:int, matches:[^]Match_Parse_Record) -> int {
    e:=c.e
    o:=&e.options
    chunk_ptr:=c.chunk_ptr
    chunk_len:=c.chunk_len
    ea:parse.Encoder_Arrays
    parse.arrays_point_to_scratch(&ea,raw_data(e.arrays_space),chunk_len,chunk_ptr,e.bitstream_flags)
    los:parse.LOs
    parse.los_reset(&los)
    start_pos:=c.chunk_pos==0 ? compressor.MIN_OFFSET : 0
    dict_size:=parse.dictionary_size(o)
    parse_end_pos:=chunk_len-compressor.LZ_NO_MATCH_ZONE
    ptr_matchend:=chunk_ptr[chunk_len-compressor.LZ_MATCH_END_PAD:]
    literals_start:=start_pos
    for pos:=start_pos;pos<parse_end_pos; {
        ptr:=chunk_ptr[pos:]
        chosen:=get_match_heuristic_pairs(&matches[pos],&los,ptr,ptr_matchend,mml,
            pos-literals_start,
            c.dictionary_base,dict_size,o)
        if chosen.ml==0 {pos+=1;continue}
        for pos+1<parse_end_pos {
            lazy:=get_match_heuristic_pairs(&matches[pos+1],&los,ptr[1:],ptr_matchend,mml,
                pos+1-literals_start,
                c.dictionary_base,dict_size,o)
            if parse.lazy_match_delta(lazy.ml,lazy.off,parse.is_lo(lazy),chosen.ml,chosen.off,parse.is_lo(chosen))>0 {
                ptr=ptr[1:];pos+=1
                chosen=lazy
            } else {
                if pos+2>=parse_end_pos {break}
                lazy=get_match_heuristic_pairs(&matches[pos+2],&los,ptr[2:],ptr_matchend,mml,
                    pos+2-literals_start,
                    c.dictionary_base,dict_size,o)
                if parse.lazy_match_delta(lazy.ml,lazy.off,parse.is_lo(lazy),chosen.ml,chosen.off,
                    parse.is_lo(chosen))>parse.LAZYBETTER_LAZY2 {
                    ptr=ptr[2:];pos+=2
                    chosen=lazy
                } else {
                    break
                }
            }
        }
        if chosen.off==0 && pos==literals_start {
            if los.lasts[1]==los.lasts[0] {chosen.off=-1} else {chosen.off=los.lasts[0]}
        }
        lrl:=pos-literals_start
        parse.arrays_put_packet(&ea,&los,lrl,int(chosen.ml),int(chosen.off),chunk_ptr[literals_start:],
            false,true)
        pos+=int(chosen.ml)
        literals_start=pos
    }
    parse.arrays_finish_chunk(&ea,chunk_ptr[literals_start:],true)
    return parse.arrays_output(c,pJ,pchunktype,passinfo,comp,comp_end,&ea,compressor.LEVEL_NORMAL,
        e.entropy_flags&~entropy.ARRAY_FLAG_ALLOW_SPLIT)
}

@(private) HISTO_INC :: 2

// Adds the literals, packets, offsets and excesses of a parse piece to the running histograms.
@(private)
optimal_update_passinfo :: proc "contextless" (parsevec:[]parse.Parse, parse_start_pos:int, pi:^parse.Passinfo,
    chunk:[^]u8) #no_bounds_check {
    start:=parse_start_pos
    for &p in parsevec {
        lrl:=int(p.lrl)
        pos:=start
        lastoffset:=int(p.lastoffset)
        start+=lrl+int(p.ml)
        for _ in 0..<lrl {
            lit:=chunk[pos]
            pi.literal_histo_raw[lit]+=HISTO_INC
            ref:=padd(chunk,pos-lastoffset)[0]
            pi.literal_histo_sub[lit-ref]+=HISTO_INC
            pos+=1
        }
        lrl_for_packet:=min(lrl,compressor.LZ_LRL_MAX)
        ml_to_send:=int(p.ml)-compressor.LZ_LOMML
        ml_for_packet:=min(ml_to_send,compressor.LZ_ML_MAX)
        packet:=lrl_for_packet+(ml_for_packet<<2)
        if p.offset<=0 {
            packet+=int(-p.offset)<<6
        } else {
            packet+=3<<6
            off:=u32(p.offset)
            if pi.offset_alt_modulo==0 {
                pi.offset_histo1[parse.offset44_pack_u8(p.offset)]+=HISTO_INC
            } else if pi.offset_alt_modulo==1 {
                pi.offset_histo1[parse.alt_offset_pack_u8_modulo1(off)]+=HISTO_INC
            } else {
                top,bot:=parse.alt_offset_pack_u8s(off,u32(pi.offset_alt_modulo))
                pi.offset_histo1[top]+=HISTO_INC
                pi.offset_histo2[bot]+=HISTO_INC
            }
        }
        pi.packet_histo[packet&0xFF]+=HISTO_INC
        if lrl_for_packet==compressor.LZ_LRL_MAX {
            pi.excess_histo[min(lrl-compressor.LZ_LRL_MAX,255)]+=HISTO_INC
        }
        if ml_for_packet==compressor.LZ_ML_MAX {pi.excess_histo[min(ml_to_send-compressor.LZ_ML_MAX,
            255)]+=HISTO_INC}
    }
}

@(private)
optimal_passinfo_to_codecost :: proc(pi:^parse.Passinfo, cc:^Codecosts, mml:int) {
    threshold:=entropy.COST_ONE_BYTE-1
    ent_histo_to_codecost(pi.offset_histo1[:],cc.codecost_offset1[:],COST_PENALTY_NORMAL_MATCH,
        threshold)
    if pi.offset_alt_modulo>1 {
        ent_histo_to_codecost(pi.offset_histo2[:],cc.codecost_offset2[:],0,threshold)
    }
    ent_histo_to_codecost(pi.packet_histo[:],cc.codecost_packet[:],COST_PENALTY_PACKET,threshold)
    ent_histo_to_codecost(pi.excess_histo[:],cc.codecost_excess[:],COST_PENALTY_EXCESS,threshold)
    if cc.chunktype==compressor.CHUNK_LITERALS_RAW {
        ent_histo_to_codecost(pi.literal_histo_raw[:],cc.codecost_literal[:],0,threshold)
    } else {
        ent_histo_to_codecost(pi.literal_histo_sub[:],cc.codecost_literal[:],0,threshold)
    }
    for packet_lrl in 0..<4 {
        for loi in 0..<4 {
            ml_base:=loi==3 ? mml-compressor.LZ_LOMML : 0
            for slot in 0..<SHORTCOST_COUNT {
                rel_ml:=slot+ml_base
                packet_ml:=min(rel_ml,compressor.LZ_ML_MAX)
                packet:=packet_lrl+(packet_ml<<2)+(loi<<6)
                cost:=cc.codecost_packet[packet]
                if rel_ml>=compressor.LZ_ML_MAX {
                    cost+=cc.codecost_excess[min(rel_ml-compressor.LZ_ML_MAX,255)]
                }
                cc.cost_packet_short[packet_lrl][loi][slot]=cost
            }
        }
    }
}

@(private)
rescale_histo :: proc "contextless" (h:^[256]u32) {for &v in h {v=1+(v>>4)}}

@(private)
rescale_histo2 :: proc "contextless" (h1:^[256]u32,
    h2:^[256]u32) {for i in 0..<256 {h1[i]=1+((h1[i]+h2[i])>>5)}}

@(private)
optimal_rescale_passinfo :: proc "contextless" (pi:^parse.Passinfo) {
    rescale_histo(&pi.literal_histo_raw)
    rescale_histo(&pi.literal_histo_sub)
    rescale_histo(&pi.offset_histo1)
    if pi.offset_alt_modulo>1 {rescale_histo(&pi.offset_histo2)}
    rescale_histo(&pi.packet_histo)
    rescale_histo(&pi.excess_histo)
}

// pi1 = this chunk's greedy pass, pi2 = the previous chunk's optimal pass.
@(private)
optimal_rescale_passinfo2 :: proc "contextless" (pi1:^parse.Passinfo, pi2:^parse.Passinfo, literals_same:bool) {
    if literals_same {
        rescale_histo2(&pi1.literal_histo_raw,&pi2.literal_histo_raw)
        rescale_histo2(&pi1.literal_histo_sub,&pi2.literal_histo_sub)
    } else {
        rescale_histo(&pi1.literal_histo_raw)
        rescale_histo(&pi1.literal_histo_sub)
    }
    rescale_histo2(&pi1.packet_histo,&pi2.packet_histo)
    rescale_histo2(&pi1.excess_histo,&pi2.excess_histo)
    if pi1.offset_alt_modulo==pi2.offset_alt_modulo {
        rescale_histo2(&pi1.offset_histo1,&pi2.offset_histo1)
        if pi1.offset_alt_modulo>1 {rescale_histo2(&pi1.offset_histo2,&pi2.offset_histo2)}
    } else {
        pi1.offset_histo1=pi2.offset_histo1
        pi1.offset_histo2=pi2.offset_histo2
        pi1.offset_alt_modulo=pi2.offset_alt_modulo
        rescale_histo(&pi1.offset_histo1)
        if pi1.offset_alt_modulo>1 {rescale_histo(&pi1.offset_histo2)}
    }
}

// Arguments of the parse core that stay fixed through a chunk.
@(private)
Parse_Ctx :: struct {
    chunk_ptr:[^]u8, chunk_len:int, start_pos:int,
    parse_chunk_len,parse_chunk_len_max:int,
    dictionary_base:[^]u8, dictionary_size:u32,
    matches:[^]Match_Parse_Record, mml:int, max_search_lrl:int,
    arr:^Arrivals, last_tll:int, last_tll_len:[^]i32,
    level:i32, o:^parse.Options,
    passinfo:^parse.Passinfo, cc:^Codecosts,
    parsevec:[]parse.Parse, parsevec_len:int,
    chunk_parsevec:[]parse.Parse,
}

@(private)
parse_tll_core :: proc(x:^Parse_Ctx, $NUM_TLLS:int) -> bool #no_bounds_check {
    MAX_MATCH_CANDIDATES :: 8+1
    num_tlls:=NUM_TLLS
    chunk_ptr:=x.chunk_ptr
    chunk_len:=x.chunk_len
    arr:=x.arr
    cc:=x.cc
    last_tll:=x.last_tll
    last_tll_len:=x.last_tll_len
    mml:=x.mml
    max_search_lrl:=x.max_search_lrl
    parse_end_pos:=chunk_len-compressor.LZ_NO_MATCH_ZONE
    ptr_matchend:=chunk_ptr[chunk_len-compressor.LZ_MATCH_END_PAD:]
    optimal_skip_len:=1<<uint(min(int(x.level),8))
    lored_lo,lored_hi:=compressor.LZ_LOMML+1,optimal_skip_len
    mred_lo,mred_hi:=mml+1,optimal_skip_len
    twostep_end_pos:=parse_end_pos-(TWO_STEP_MAX_LRL+compressor.LZ_LOMML)
    twostep_lo_end_pos:=twostep_end_pos
    cost_update_interval:=x.level>=compressor.LEVEL_OPTIMAL2 ? 1 : 1024
    avail_base:=x.dictionary_base

    parse_chunk_start:=x.start_pos
    last_cost_update_pos:=x.start_pos
    x.parsevec_len=0

    for {
        if parse_chunk_start>=parse_end_pos {break}
        parse_chunk_end:=min(parse_chunk_start+x.parse_chunk_len,parse_end_pos)
        parse_chunk_end_max:=min(parse_chunk_start+x.parse_chunk_len_max,parse_end_pos)
        if parse_chunk_end_max>=parse_end_pos-16 {parse_chunk_end_max=parse_end_pos}
        if parse_chunk_end>=parse_end_pos-16 {parse_chunk_end=parse_end_pos}
        cheap_preceding_arrival_pos:=parse_chunk_start
        cheap_preceding_arrival_literal_cost:i32

        inner: {
            when NUM_TLLS>1 {
                for p in 1..<NUM_TLLS {
                    for t in 0..<NUM_TLLS {arr.cost[(parse_chunk_start+p)*NUM_TLLS+t]=S32_MAX}
                }
                for t in 1..<NUM_TLLS {arr.cost[parse_chunk_start*NUM_TLLS+t]=S32_MAX}
                if parse_chunk_end-parse_chunk_start<=NUM_TLLS {
                    parse_chunk_end=parse_chunk_start
                    parse_end_pos=parse_chunk_start
                    break inner
                }
                for t in 1..<NUM_TLLS {
                    dest:=(parse_chunk_start+t)*NUM_TLLS+t
                    src:=(parse_chunk_start+t-1)*NUM_TLLS+(t-1)
                    arr.a[dest]=arr.a[src]
                    lo:=arr.a[parse_chunk_start*NUM_TLLS].los.lasts[0]
                    arr.cost[dest]=arr.cost[src]+cost_add_literal(chunk_ptr,parse_chunk_start+t-1,
                        lo,cc)
                }
                last_tll_len[parse_chunk_start+last_tll]=i32(last_tll)
            }

            for pos:=parse_chunk_start;parse_chunk_end<=parse_chunk_end_max;pos+=1 {
                if pos==parse_end_pos {
                    parse_chunk_end=parse_end_pos
                    break
                }
                ptr:=chunk_ptr[pos:]
                ptr32:=load32(ptr)
                my_arrivals:=arr.a[pos*NUM_TLLS:]
                my_costs:=arr.cost[pos*NUM_TLLS:]

                when NUM_TLLS==1 {
                    if pos!=cheap_preceding_arrival_pos {
                        lo:=arr.a[cheap_preceding_arrival_pos].los.lasts[0]
                        cheap_preceding_arrival_literal_cost+=cost_add_literal(chunk_ptr,pos-1,lo,
                            cc)
                        if arr.cost[pos]!=S32_MAX {
                            lrl:=pos-cheap_preceding_arrival_pos
                            prev_cost:=arr.cost[cheap_preceding_arrival_pos]
                            cost_lrl:i32
                            if lrl>=compressor.LZ_LRL_MAX {
                                cost_lrl=cost_excess(lrl-compressor.LZ_LRL_MAX,cc)
                            }
                            cost:=prev_cost+cost_lrl+cheap_preceding_arrival_literal_cost
                            if cost>arr.cost[pos] {
                                cheap_preceding_arrival_pos=pos
                                cheap_preceding_arrival_literal_cost=0
                                if pos>=parse_chunk_end {
                                    parse_chunk_end=pos
                                    break inner
                                }
                            }
                        }
                    }
                } else {
                    if pos>=parse_chunk_end {
                        lowest_cost:=S32_MAX
                        lowest_arrival_pos:=0
                        for t in 0..<NUM_TLLS {
                            if my_costs[t]<lowest_cost {
                                lowest_cost=my_costs[t]
                                ap:=pos
                                if t==last_tll {ap-=int(last_tll_len[pos])} else {ap-=t}
                                lowest_arrival_pos=ap
                            }
                        }
                        if lowest_arrival_pos>=parse_chunk_end {
                            parse_chunk_end=lowest_arrival_pos
                            break inner
                        }
                    }
                    if my_costs[last_tll]!=S32_MAX {
                        lo:=my_arrivals[last_tll].los.lasts[0]
                        cost:=my_costs[last_tll]+cost_add_literal(chunk_ptr,pos,lo,cc)
                        if cost<my_costs[last_tll+NUM_TLLS] {
                            my_arrivals[last_tll+NUM_TLLS]=my_arrivals[last_tll]
                            my_costs[last_tll+NUM_TLLS]=cost
                            last_tll_len[pos+1]=last_tll_len[pos]+1
                        }
                    }
                }

                pairs:=&x.matches[pos].pairs
                longestml:=0
                lowest_base_cost:=S32_MAX
                match_lrl:[MAX_MATCH_CANDIDATES]i32
                match_base_cost:[MAX_MATCH_CANDIDATES]i32
                match_prev_index:[MAX_MATCH_CANDIDATES]i32
                match_longestlo:[MAX_MATCH_CANDIDATES]i32
                ncand:=0
                cheap_preceding_arrival_lrl:=pos-cheap_preceding_arrival_pos

                lrl_loop: for lrl_iterator:=0;;lrl_iterator+=1 {
                    base_cost:i32
                    lrl:int
                    prev_index:int
                    when NUM_TLLS==1 {
                        if lrl_iterator>max_search_lrl {break}
                        lrl=lrl_iterator
                        if lrl==max_search_lrl && cheap_preceding_arrival_lrl>max_search_lrl {
                            lrl=cheap_preceding_arrival_lrl
                        }
                        prev_index=pos-lrl
                        if prev_index<parse_chunk_start {break}
                        arrival_cost:=arr.cost[prev_index]
                        if arrival_cost==S32_MAX {continue}
                        base_cost=arrival_cost
                        lo:=arr.a[prev_index].los.lasts[0]
                        if lrl==cheap_preceding_arrival_lrl {
                            base_cost+=cheap_preceding_arrival_literal_cost
                        } else {
                            base_cost+=cost_literals(chunk_ptr,pos-lrl,lrl,lo,cc)
                        }
                    } else {
                        if lrl_iterator<NUM_TLLS {
                            arrival_cost:=my_costs[lrl_iterator]
                            if arrival_cost==S32_MAX {continue}
                            lrl=lrl_iterator
                            if lrl_iterator==last_tll {lrl=int(last_tll_len[pos])}
                            prev_index=pos*NUM_TLLS+lrl_iterator
                            base_cost=arrival_cost
                        } else {
                            if lrl_iterator>max_search_lrl {break}
                            lrl=lrl_iterator-1
                            if pos-lrl<parse_chunk_start {break}
                            prev_index=(pos-lrl)*NUM_TLLS
                            arrival_cost:=arr.cost[prev_index]
                            if arrival_cost==S32_MAX {continue}
                            base_cost=arrival_cost+cost_literals(chunk_ptr,pos-lrl,lrl,
                                arr.a[prev_index].los.lasts[0],cc)
                        }
                    }
                    lrl_for_packet:=lrl
                    if lrl>=compressor.LZ_LRL_MAX {
                        lrl_for_packet=compressor.LZ_LRL_MAX
                        base_cost+=cost_excess(lrl-compressor.LZ_LRL_MAX,cc)
                    }
                    los:=&arr.a[prev_index].los
                    longestlo:=0
                    for loi in 0..<compressor.LZ_NUM_LAST_OFFSETS {
                        offset:=los.lasts[loi]
                        ml:int
                        if !match.havematch_mml2_one32(ptr32,ptr,padd(ptr,-int(offset)),
                            ptr_matchend,&ml) {continue}
                        if ml<=longestlo {continue}
                        longestlo=ml
                        parse_chunk_end=max(parse_chunk_end,pos+ml)
                        first_step_cost:i32
                        if NUM_TLLS!=1 || ml>=SHORT_ENDML {
                            first_step_cost=try_lo_arrival_tll(arr,NUM_TLLS,prev_index,chunk_ptr,
                                last_tll_len,
                                pos,base_cost,lrl,lrl_for_packet,ml,loi,los,cc)
                            if ml>=lored_lo && ml<lored_hi {
                                for l in compressor.LZ_LOMML..<ml {
                                    try_lo_arrival_tll(arr,NUM_TLLS,prev_index,chunk_ptr,
                                        last_tll_len,
                                        pos,base_cost,lrl,lrl_for_packet,l,loi,los,cc)
                                }
                            }
                        } else {
                            costs:=&cc.cost_packet_short[lrl_for_packet][loi]
                            first_step_cost=base_cost+costs[ml-compressor.LZ_LOMML]
                            ac:=arr.cost[pos+compressor.LZ_LOMML:]
                            for i in 0..=ml-compressor.LZ_LOMML {
                                cand:=base_cost+costs[i]
                                if cand<ac[i] {
                                    ac[i]=cand
                                    arrival_set_lo(&arr.a[pos+compressor.LZ_LOMML+i],prev_index,lrl,
                                        i+compressor.LZ_LOMML,loi,los)
                                }
                            }
                        }
                        if pos+ml<twostep_lo_end_pos {
                            try_two_step_arrival_tll(arr,NUM_TLLS,prev_index,chunk_ptr,
                                ptr_matchend,&parse_chunk_end,
                                pos+ml,first_step_cost,ml,lrl,loi,offset,los,cc)
                        }
                    }
                    longestml=max(longestlo,longestml)
                    if longestml>=optimal_skip_len {break lrl_loop}
                    if base_cost<lowest_base_cost {
                        if ncand>=MAX_MATCH_CANDIDATES {return false}
                        lowest_base_cost=base_cost
                        match_lrl[ncand]=i32(lrl)
                        match_base_cost[ncand]=base_cost
                        match_prev_index[ncand]=i32(prev_index)
                        match_longestlo[ncand]=i32(longestlo)
                        ncand+=1
                    }
                }

                if longestml<optimal_skip_len {
                    if lowest_base_cost==S32_MAX {return false}
                    for m in 0..<match.NEWLZ_MATCH_NUM_PAIRS {
                        ml:=int(pairs[m].length)
                        if ml<mml {break}
                        offset:=u32(pairs[m].offset)
                        ml=min(ml,pdiff(ptr_matchend,ptr))
                        if offset>=x.dictionary_size {continue}
                        avail:=pdiff(ptr,avail_base)
                        if offset<compressor.MIN_OFFSET {
                            offset=round_up_small_offset(offset)
                            if int(offset)>avail {continue}
                            ml=match.getmatchlen_mml4_one32(ptr32,ptr,padd(ptr,-int(offset)),
                                ptr_matchend)
                            if offset!=compressor.MIN_OFFSET {
                                minml:=match.getmatchlen_mml4_one32(ptr32,ptr,padd(ptr,
                                    -compressor.MIN_OFFSET),ptr_matchend)
                                if minml>=ml {offset=compressor.MIN_OFFSET;ml=minml}
                            }
                            if ml<mml {continue}
                        } else if int(offset)>avail {continue}
                        if !parse.is_allowed_normal_match_optimal(i32(ml),offset,x.o) {continue}
                        best_cost:=S32_MAX
                        best_i:=-1
                        for i in 0..<ncand {
                            my_packet_lrl:=min(int(match_lrl[i]),compressor.LZ_LRL_MAX)
                            my_cost:=match_base_cost[i]+cost_normal_match(my_packet_lrl,ml,cc)
                            if my_cost<best_cost {best_cost=my_cost;best_i=i}
                        }
                        if best_i<0 {continue}
                        base_cost:=match_base_cost[best_i]
                        prev_index:=int(match_prev_index[best_i])
                        lrl:=int(match_lrl[best_i])
                        longestlo:=int(match_longestlo[best_i])
                        lrl_for_packet:=min(lrl,compressor.LZ_LRL_MAX)
                        los:=&arr.a[prev_index].los
                        if ml<=longestlo {break}
                        longestml=max(ml,longestml)
                        parse_chunk_end=max(parse_chunk_end,pos+ml)
                        cost:=base_cost+cost_offset(offset,cc)
                        first_step_cost:i32
                        if NUM_TLLS!=1 || ml>=SHORT_ENDML {
                            first_step_cost=try_match_arrival_tll(arr,NUM_TLLS,prev_index,
                                chunk_ptr,last_tll_len,
                                pos,cost,lrl,lrl_for_packet,ml,offset,los,cc)
                            if ml>=mred_lo && ml<mred_hi {
                                for l in mml..<ml {
                                    try_match_arrival_tll(arr,NUM_TLLS,prev_index,chunk_ptr,
                                        last_tll_len,
                                        pos,cost,lrl,lrl_for_packet,l,offset,los,cc)
                                }
                            }
                        } else {
                            costs:=&cc.cost_packet_short[lrl_for_packet][3]
                            first_step_cost=cost+costs[ml-mml]
                            ac:=arr.cost[pos+mml:]
                            for i in 0..=ml-mml {
                                cand:=cost+costs[i]
                                if cand<ac[i] {
                                    ac[i]=cand
                                    arrival_set_match(&arr.a[pos+mml+i],prev_index,lrl,i+mml,
                                        offset,los)
                                }
                            }
                        }
                        if pos+ml<twostep_end_pos {
                            try_two_step_arrival_tll(arr,NUM_TLLS,prev_index,chunk_ptr,
                                ptr_matchend,&parse_chunk_end,
                                pos+ml,first_step_cost,ml,lrl,-1,i32(offset),los,cc)
                        }
                    }
                }

                if longestml>=optimal_skip_len {
                    lap:=pos+longestml
                    if lap==parse_chunk_end {
                        parse_chunk_end=lap
                        cheap_preceding_arrival_pos=lap
                        break inner
                    }
                    pos=lap-1
                    when NUM_TLLS==1 {
                        cheap_preceding_arrival_pos=pos+1
                        cheap_preceding_arrival_literal_cost=0
                    } else {
                        lo:=arr.a[lap*NUM_TLLS].los.lasts[0]
                        for t in 1..<NUM_TLLS {
                            index:=(lap+t)*NUM_TLLS+t
                            src:=(lap+t-1)*NUM_TLLS+(t-1)
                            arr.a[index]=arr.a[src]
                            arr.cost[index]=arr.cost[src]+cost_add_literal(chunk_ptr,lap+t-1,lo,cc)
                        }
                        last_tll_len[lap+last_tll]=i32(last_tll)
                    }
                }
            }
        }

        parse_chunk_end_index:=parse_chunk_end*NUM_TLLS
        is_final_arrival:=parse_chunk_end>=parse_end_pos-2
        if is_final_arrival {
            final_arrival_pos:=-1
            final_arrival_cost:=S32_MAX
            when NUM_TLLS==1 {
                backup_start:=max(cheap_preceding_arrival_pos-FINAL_EXTRA_BACKUP,parse_chunk_start)
                for pos in backup_start..<chunk_len {
                    cost:=arr.cost[pos]
                    if cost==S32_MAX {continue}
                    lo:=arr.a[pos].los.lasts[0]
                    cost+=cost_literals(chunk_ptr,pos,chunk_len-pos,lo,cc)
                    if cost<final_arrival_cost {final_arrival_cost=cost;final_arrival_pos=pos}
                }
                parse_chunk_end=final_arrival_pos
                parse_chunk_end_index=final_arrival_pos
            } else {
                backup_start:=max(parse_chunk_end-FINAL_EXTRA_BACKUP,parse_chunk_start)
                for pos in backup_start..<chunk_len {
                    for t in 0..<NUM_TLLS {
                        index:=pos*NUM_TLLS+t
                        cost:=arr.cost[index]
                        if cost==S32_MAX {continue}
                        lo:=arr.a[index].los.lasts[0]
                        lrl:=t
                        if t==last_tll {lrl=int(last_tll_len[pos])}
                        ap:=pos-lrl
                        if ap<parse_chunk_start {continue}
                        cost+=cost_literals(chunk_ptr,pos,chunk_len-pos,lo,cc)
                        if cost<final_arrival_cost {
                            final_arrival_cost=cost
                            final_arrival_pos=ap
                            parse_chunk_end=ap
                            parse_chunk_end_index=index
                        }
                    }
                }
            }
            if final_arrival_pos<0 {return false}
        }

        // trace back through the arrivals
        n:=0
        cpv:=x.chunk_parsevec
        rpos:=parse_chunk_end
        rindex:=parse_chunk_end_index
        for {
            if rpos<parse_chunk_start || rindex<0 {return false}
            if rpos==parse_chunk_start {break}
            ar:=&arr.a[rindex]
            if n+2>len(cpv) {return false}
            if ar.twostep!=0 {
                tl:=int(ar.twostep&0xFF)
                tm:=int(ar.twostep>>8)
                cpv[n]=parse.Parse{lastoffset=ar.los.lasts[0],offset=0,ml=i32(tm),lrl=i32(tl)}
                n+=1
                rpos-=tm+tl
            }
            prev_pos:=rpos-int(ar.ml)-int(ar.lrl)
            prev_index:=int(ar.prev_index)
            if prev_pos<parse_chunk_start || prev_pos>=rpos {return false}
            prev:=&arr.a[prev_index]
            offset:=ar.los.lasts[0]
            loi:=nopad_find(&prev.los,offset)
            if loi>=0 {offset=-i32(loi)}
            cpv[n]=parse.Parse{lastoffset=prev.los.lasts[0],lrl=ar.lrl,ml=ar.ml,offset=offset}
            n+=1
            rpos=prev_pos
            rindex=prev_index
        }
        if x.parsevec_len+n>len(x.parsevec) {return false}
        for i in 0..<n {x.parsevec[x.parsevec_len+i]=cpv[n-1-i]}
        x.parsevec_len+=n

        if is_final_arrival {break}
        optimal_update_passinfo(x.parsevec[x.parsevec_len-n:x.parsevec_len],parse_chunk_start,
            x.passinfo,chunk_ptr)
        if parse_chunk_end-last_cost_update_pos>=cost_update_interval {
            last_cost_update_pos=parse_chunk_end
            optimal_passinfo_to_codecost(x.passinfo,cc,mml)
        }
        parse_chunk_start=parse_chunk_end
    }
    return true
}

// newLZ_encode_chunk_optimal_tll
@(private)
encode_chunk_optimal_tll :: proc(c:^parse.Chunk, matches:[^]Match_Parse_Record, pchunktype:^i32,
    pJ:^f32) -> int {
    pchunktype^=0
    chunk_len:=c.chunk_len
    if chunk_len<=compressor.MIN_CHUNK_LEN {return chunk_len}
    e:=c.e
    o:=&e.options
    level:=e.level
    parse_chunk_len:=256
    parse_chunk_len_max:=PARSE_CHUNK_LEN_MAX
    num_tlls,max_search_lrl:int
    if level>=compressor.LEVEL_OPTIMAL4 {
        num_tlls=2;max_search_lrl=8
    } else {
        num_tlls=1
        max_search_lrl=level>=compressor.LEVEL_OPTIMAL2 ? 3 : 1
    }
    if num_tlls>1 && e.last_tll_len_space==nil {return chunk_len}
    dict_size:=parse.dictionary_size(o)
    start_pos:=c.chunk_pos==0 ? compressor.MIN_OFFSET : 0

    arrivals_count:=num_tlls*(chunk_len+1)
    asz:=arrivals_size(arrivals_count)
    if asz>len(e.arrivals_space) {return chunk_len}
    arr:=Arrivals{cost=([^]i32)(raw_data(e.arrivals_space)),
        a=([^]Arrival)(padd(raw_data(e.arrivals_space),arrivals_count*size_of(i32)))}

    comp_room:=pdiff(c.comp_end,c.comp)
    passinfo,passinfo_mml_alt:parse.Passinfo
    mml:=int(max(4,o.min_match_len))
    greedy_J:=entropy.LAGRANGE_COST_INVALID
    greedy_complen:=encode_chunk_optimal_greedy(c,&greedy_J,pchunktype,&passinfo,c.comp,c.comp_end,
        mml,matches)
    if greedy_complen<0 || greedy_complen>=chunk_len {return chunk_len}
    if c.chunk_pos!=0 && int(matches[0].pairs[0].length)>=chunk_len-compressor.LZ_NO_MATCH_ZONE {
        pJ^=greedy_J
        return greedy_complen
    }
    optimal_comp:=raw_data(e.arrivals_space)
    optimal_comp_end:=padd(optimal_comp,asz)

    if level>=compressor.LEVEL_OPTIMAL3 && o.min_match_len<=3 {
        ct3:i32
        J3:=entropy.LAGRANGE_COST_INVALID
        len3:=encode_chunk_optimal_greedy(c,&J3,&ct3,&passinfo_mml_alt,optimal_comp,
            optimal_comp_end,3,matches)
        if J3<greedy_J && len3>=0 && len3<chunk_len && len3<=comp_room {
            pchunktype^=ct3
            runtime.mem_copy(c.comp,optimal_comp,len3)
            greedy_J=J3
            greedy_complen=len3
            mml=3
            passinfo=passinfo_mml_alt
        }
    }
    if 8>o.min_match_len {
        ct8:i32
        J8:=entropy.LAGRANGE_COST_INVALID
        len8:=encode_chunk_optimal_greedy(c,&J8,&ct8,&passinfo_mml_alt,optimal_comp,
            optimal_comp_end,8,matches)
        if J8<greedy_J && len8>=0 && len8<chunk_len && len8<=comp_room {
            pchunktype^=ct8
            runtime.mem_copy(c.comp,optimal_comp,len8)
            greedy_J=J8
            greedy_complen=len8
            passinfo=passinfo_mml_alt
        }
    }
    if level>=compressor.LEVEL_OPTIMAL3 && o.min_match_len<=3 {mml=3}

    last_tll:=chunk_len
    last_tll_len:[^]i32
    if num_tlls>1 {
        last_tll=num_tlls-1
        last_tll_len=raw_data(e.last_tll_len_space)
        for i in 0..=chunk_len {last_tll_len[i]=0}
    }
    do_optimal_iter:=level>=compressor.LEVEL_OPTIMAL4
    nparse:=chunk_len/2
    if nparse+PARSE_CHUNK_LEN_MAX>len(e.parse_space) {return chunk_len}
    parsevec:=e.parse_space[:nparse]
    chunk_parsevec:=e.parse_space[nparse:nparse+PARSE_CHUNK_LEN_MAX]

    for optimal_iter:=0;;optimal_iter+=1 {
        cc:Codecosts
        cc.chunktype=pchunktype^
        cc.subliteralmask=cc.chunktype==compressor.CHUNK_LITERALS_RAW ? 0 : ~u32(0)
        if e.carried_chunktype>=0 {
            optimal_rescale_passinfo2(&passinfo,&e.carried_passinfo,
                e.carried_chunktype==cc.chunktype)
        } else {
            optimal_rescale_passinfo(&passinfo)
        }
        cc.offset_alt_modulo=passinfo.offset_alt_modulo
        optimal_passinfo_to_codecost(&passinfo,&cc,mml)
        for i in 0..=chunk_len*num_tlls {arr.cost[i]=S32_MAX}
        {
            i0:=start_pos*num_tlls
            arr.cost[i0]=0
            a:=&arr.a[i0]
            a.los.lasts={compressor.MIN_OFFSET,compressor.MIN_OFFSET,compressor.MIN_OFFSET}
            a.ml=0;a.lrl=0;a.prev_index=0;a.twostep=0
        }
        x:=Parse_Ctx{chunk_ptr=c.chunk_ptr,chunk_len=chunk_len,start_pos=start_pos,
            parse_chunk_len=parse_chunk_len,parse_chunk_len_max=parse_chunk_len_max,
            dictionary_base=c.dictionary_base,dictionary_size=dict_size,matches=matches,mml=mml,
            max_search_lrl=max_search_lrl,arr=&arr,last_tll=last_tll,last_tll_len=last_tll_len,
            level=level,o=o,passinfo=&passinfo,cc=&cc,parsevec=parsevec,
                chunk_parsevec=chunk_parsevec}
        ok:bool
        if num_tlls==1 {ok=parse_tll_core(&x,1)} else {ok=parse_tll_core(&x,2)}
        if !ok {
            pJ^=greedy_J
            return greedy_complen
        }
        optimal_chunktype:i32
        optimal_J:=entropy.LAGRANGE_COST_INVALID
        optimal_complen:=put_parse(c,&optimal_J,&optimal_chunktype,optimal_comp,optimal_comp_end,
            parsevec[:x.parsevec_len],&passinfo)
        if optimal_J<greedy_J && optimal_complen>=0 && optimal_complen<chunk_len &&
            optimal_complen<=comp_room {
            pchunktype^=optimal_chunktype
            pJ^=optimal_J
            runtime.mem_copy(c.comp,optimal_comp,optimal_complen)
            if do_optimal_iter && optimal_iter==0 && cc.chunktype!=optimal_chunktype {
                e.carried_chunktype=-1
                greedy_J=optimal_J
                greedy_complen=optimal_complen
                continue
            }
            e.carried_passinfo=passinfo
            e.carried_chunktype=optimal_chunktype
            return optimal_complen
        }
        pJ^=greedy_J
        return greedy_complen
    }
}

// newLZ_put_parse: replays a parse into the arrays and outputs them.
@(private)
put_parse :: proc(c:^parse.Chunk, pJ:^f32, pchunktype:^i32, comp,comp_end:[^]u8, parsevec:[]parse.Parse,
    passinfo:^parse.Passinfo) -> int {
    pJ^=entropy.LAGRANGE_COST_INVALID
    if len(parsevec)==0 {return c.chunk_len}
    e:=c.e
    ea:parse.Encoder_Arrays
    parse.arrays_point_to_scratch(&ea,raw_data(e.arrays_space),c.chunk_len,c.chunk_ptr,e.bitstream_flags)
    dummy:parse.LOs
    parse.los_reset(&dummy)
    start_pos:=c.chunk_pos==0 ? compressor.MIN_OFFSET : 0
    literals_start:=c.chunk_ptr[start_pos:]
    for &p in parsevec {
        parse.arrays_put_packet(&ea,&dummy,int(p.lrl),int(p.ml),int(p.offset),literals_start,false,true)
        literals_start=literals_start[p.lrl+p.ml:]
    }
    parse.arrays_finish_chunk(&ea,literals_start,true)
    return parse.arrays_output(c,pJ,pchunktype,passinfo,comp,comp_end,&ea,e.level,e.entropy_flags)
}

@(private)
ent_histo_to_codecost :: #force_inline proc "contextless" (histo:[]u32, codecost:[]i32,
    add_cost:int, threshold:int) {
    entropy.histo_to_codecost(histo,codecost,len(histo),add_cost,threshold)
}
