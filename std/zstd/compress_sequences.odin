package zstd

import "base:intrinsics"

Default_Policy :: enum {Disallowed,Allowed}

// -log2(x/256)*256, rounded down, 0 for x=0.
@(rodata,private="file") Inverse_Probability_Log256:=[256]u32{
    0,2048,1792,1642,1536,1453,1386,1329,1280,1236,1197,1162,
    1130,1100,1073,1047,1024,1001,980,960,941,923,906,889,
    874,859,844,830,817,804,791,779,768,756,745,734,
    724,714,704,694,685,676,667,658,650,642,633,626,
    618,610,603,595,588,581,574,567,561,554,548,542,
    535,529,523,517,512,506,500,495,489,484,478,473,
    468,463,458,453,448,443,438,434,429,424,420,415,
    411,407,402,398,394,390,386,382,377,373,370,366,
    362,358,354,350,347,343,339,336,332,329,325,322,
    318,315,311,308,305,302,298,295,292,289,286,282,
    279,276,273,270,267,264,261,258,256,253,250,247,
    244,241,239,236,233,230,228,225,222,220,217,215,
    212,209,207,204,202,199,197,194,192,190,187,185,
    182,180,178,175,173,171,168,166,164,162,159,157,
    155,153,151,149,146,144,142,140,138,136,134,132,
    130,128,126,123,121,119,117,115,114,112,110,108,
    106,104,102,100,98,96,94,93,91,89,87,85,
    83,82,80,78,76,74,73,71,69,67,66,64,
    62,61,59,57,55,54,52,50,49,47,46,44,
    42,41,39,37,36,34,33,31,30,28,26,25,
    23,22,20,19,17,16,14,13,11,10,8,7,
    5,4,2,1,
}

@(private="file")
get_fse_max_symbol_value :: proc "contextless" (ctable:[^]u32) -> u32 {
    return u32(read16(padd(([^]u8)(ctable),2)))
}

@(private="file") use_low_prob_count :: #force_inline proc "contextless" (nb_seq:int) -> bool {return nb_seq>=2048}

@(private="file")
ncount_cost :: proc "contextless" (count:[^]u32,max_value:u32,nb_seq:int,fse_log:u32) -> (size:int,err:Error) {
    wksp:[FSE_NCOUNTBOUND]u8=---
    norm:[MAX_SEQ+1]i16=---
    table_log:=fse_optimal_table_log(fse_log,nb_seq,max_value)
    _=fse_normalize_count(([^]i16)(&norm),table_log,count,nb_seq,max_value,use_low_prob_count(nb_seq)) or_return
    return fse_write_ncount(([^]u8)(&wksp),size_of(wksp),([^]i16)(&norm),max_value,table_log)
}

@(private="file")
entropy_cost :: proc "contextless" (count:[^]u32,max_value:u32,total:int) -> u64 #no_bounds_check {
    cost:=u32(0)
    for s:=u32(0);s<=max_value;s+=1 {
        norm:=u32(u64(256*count[s])/u64(total))
        if count[s]!=0 && norm==0 {norm=1}
        cost+=count[s]*Inverse_Probability_Log256[norm]
    }
    return u64(cost>>8)
}

// The cost in bits of encoding the distribution in count with ctable; an error if ctable cannot
// represent every symbol of count.
zstd_fse_bit_cost :: proc "contextless" (ctable:[^]u32,count:[^]u32,max_value:u32) -> (size:int,err:Error) {
    ACCURACY_LOG :: 8
    cost:=u64(0)
    cstate:Fse_CState
    fse_init_cstate(&cstate,ctable)
    if get_fse_max_symbol_value(ctable)<max_value {return 0,.Generic}
    for s:=u32(0);s<=max_value;s+=1 {
        table_log:=cstate.state_log
        bad_cost:=(table_log+1)<<ACCURACY_LOG
        bit_cost:=fse_bit_cost(cstate.symbol_tt,table_log,s,ACCURACY_LOG)
        if count[s]==0 {continue}
        if bit_cost>=bad_cost {return 0,.Generic}
        cost+=u64(count[s])*u64(bit_cost)
    }
    return int(cost>>ACCURACY_LOG),.None
}

// The cost in bits of encoding the distribution in count with norm, which is valid for every
// symbol of count.
cross_entropy_cost :: proc "contextless" (norm:[^]i16,accuracy_log:u32,count:[^]u32,max_value:u32) -> int #no_bounds_check {
    shift:=8-accuracy_log
    cost:=u64(0)
    for s:=u32(0);s<=max_value;s+=1 {
        norm_acc:=norm[s]!=-1 ? u32(norm[s]) : 1
        norm256:=norm_acc<<shift
        cost+=u64(count[s]*Inverse_Probability_Log256[norm256])
    }
    return int(cost>>8)
}

// An error stands for the largest cost, as the comparisons below expect.
@(private="file") ERROR_COST :: ~u64(0)

select_encoding_type :: proc "contextless" (repeat_mode:^Fse_Repeat,count:[^]u32,max_value:u32,most_frequent,nb_seq:int,fse_log:u32,prev_ctable:[^]u32,default_norm:[^]i16,default_norm_log:u32,is_default_allowed:Default_Policy,strategy:Strategy) -> Symbol_Encoding_Type {
    default_allowed:=is_default_allowed==.Allowed
    if most_frequent==nb_seq {
        repeat_mode^=.None
        if default_allowed && nb_seq<=2 {return .Basic}
        return .RLE
    }
    if strategy<.Lazy {
        if default_allowed {
            STATIC_FSE_NB_SEQ_MAX :: 1000
            mult:=10-int(u32(strategy))
            BASE_LOG :: 3
            dynamic_fse_nb_seq_min:=((int(1)<<default_norm_log)*mult)>>BASE_LOG
            if repeat_mode^==.Valid && nb_seq<STATIC_FSE_NB_SEQ_MAX {return .Repeat}
            if nb_seq<dynamic_fse_nb_seq_min || most_frequent<(nb_seq>>(default_norm_log-1)) {
                repeat_mode^=.None
                return .Basic
            }
        }
    } else {
        basic_cost:=ERROR_COST
        if default_allowed {basic_cost=u64(cross_entropy_cost(default_norm,default_norm_log,count,max_value))}
        repeat_cost:=ERROR_COST
        if repeat_mode^!=.None {
            if cost,cost_err:=zstd_fse_bit_cost(prev_ctable,count,max_value);cost_err==.None {repeat_cost=u64(cost)}
        }
        n_count_cost:=ERROR_COST
        if cost,cost_err:=ncount_cost(count,max_value,nb_seq,fse_log);cost_err==.None {n_count_cost=u64(cost)}
        compressed_cost:=(n_count_cost<<3)+entropy_cost(count,max_value,nb_seq)

        if basic_cost<=repeat_cost && basic_cost<=compressed_cost {
            repeat_mode^=.None
            return .Basic
        }
        if repeat_cost<=compressed_cost {return .Repeat}
    }
    repeat_mode^=.Check
    return .Compressed
}

@(private="file") Build_CTable_Wksp :: struct {
    norm:[MAX_SEQ+1]i16,
    wksp:[((MAX_SEQ+2)+(1<<MAX_FSE_LOG))/2+size_of(u64)/size_of(u32)]u32,
}

build_ctable :: proc "contextless" (dst:[^]u8,dst_capacity:int,next_ctable:[^]u32,fse_log:u32,set_type:Symbol_Encoding_Type,count:[^]u32,max_value:u32,code_table:[^]u8,nb_seq:int,default_norm:[^]i16,default_norm_log,default_max:u32,prev_ctable:[^]u32,prev_ctable_size:int,entropy_workspace:[^]u8,entropy_workspace_size:int) -> (size:int,err:Error) {
    op:=dst
    oend:=padd(op,dst_capacity)

    switch set_type {
    case .RLE:
        fse_build_ctable_rle(next_ctable,u8(max_value)) or_return
        if dst_capacity==0 {return 0,.Dst_Size_Too_Small}
        op[0]=code_table[0]
        return 1,.None
    case .Repeat:
        intrinsics.mem_copy_non_overlapping(next_ctable,prev_ctable,prev_ctable_size)
        return 0,.None
    case .Basic:
        fse_build_ctable_wksp(next_ctable,default_norm,default_max,default_norm_log,entropy_workspace,entropy_workspace_size) or_return
        return 0,.None
    case .Compressed:
        wksp:=(^Build_CTable_Wksp)(entropy_workspace)
        nb_seq_1:=nb_seq
        table_log:=fse_optimal_table_log(fse_log,nb_seq,max_value)
        if count[code_table[nb_seq-1]]>1 {
            count[code_table[nb_seq-1]]-=1
            nb_seq_1-=1
        }
        fse_normalize_count(([^]i16)(&wksp.norm),table_log,count,nb_seq_1,max_value,use_low_prob_count(nb_seq_1)) or_return
        n_count_size:=fse_write_ncount(op,pdiff(oend,op),([^]i16)(&wksp.norm),max_value,table_log) or_return
        fse_build_ctable_wksp(next_ctable,([^]i16)(&wksp.norm),max_value,table_log,([^]u8)(&wksp.wksp),size_of(wksp.wksp)) or_return
        return n_count_size,.None
    }
    return 0,.Generic
}

@(private="file") STREAM_ACCUMULATOR_MIN_64 :: 57

encode_sequences :: proc "contextless" (dst:[^]u8,dst_capacity:int,ctable_match_length:[^]u32,ml_code_table:[^]u8,ctable_offset_bits:[^]u32,of_code_table:[^]u8,ctable_lit_length:[^]u32,ll_code_table:[^]u8,sequences:[^]Seq_Def,nb_seq:int,long_offsets:bool) -> (size:int,err:Error) #no_bounds_check {
    block_stream:Bit_CStream
    state_match_length,state_offset_bits,state_lit_length:Fse_CState

    if _,init_err:=bit_init_cstream(&block_stream,dst,dst_capacity);init_err!=.None {return 0,.Dst_Size_Too_Small}

    fse_init_cstate2(&state_match_length,ctable_match_length,u32(ml_code_table[nb_seq-1]))
    fse_init_cstate2(&state_offset_bits,ctable_offset_bits,u32(of_code_table[nb_seq-1]))
    fse_init_cstate2(&state_lit_length,ctable_lit_length,u32(ll_code_table[nb_seq-1]))
    bit_add_bits(&block_stream,u64(sequences[nb_seq-1].lit_length),u32(LL_bits[ll_code_table[nb_seq-1]]))
    bit_add_bits(&block_stream,u64(sequences[nb_seq-1].ml_base),u32(ML_bits[ml_code_table[nb_seq-1]]))
    if long_offsets {
        of_bits:=u32(of_code_table[nb_seq-1])
        extra_bits:=of_bits-min(of_bits,STREAM_ACCUMULATOR_MIN_64-1)
        if extra_bits!=0 {
            bit_add_bits(&block_stream,u64(sequences[nb_seq-1].off_base),extra_bits)
            bit_flush_bits(&block_stream)
        }
        bit_add_bits(&block_stream,u64(sequences[nb_seq-1].off_base>>extra_bits),of_bits-extra_bits)
    } else {
        bit_add_bits(&block_stream,u64(sequences[nb_seq-1].off_base),u32(of_code_table[nb_seq-1]))
    }
    bit_flush_bits(&block_stream)

    for n:=nb_seq-2;n>=0;n-=1 {
        ll_code:=ll_code_table[n]
        of_code:=of_code_table[n]
        ml_code:=ml_code_table[n]
        ll_bits:=u32(LL_bits[ll_code])
        of_bits:=u32(of_code)
        ml_bits:=u32(ML_bits[ml_code])
        fse_encode_symbol(&block_stream,&state_offset_bits,u32(of_code))
        fse_encode_symbol(&block_stream,&state_match_length,u32(ml_code))
        fse_encode_symbol(&block_stream,&state_lit_length,u32(ll_code))
        if of_bits+ml_bits+ll_bits>=64-7-(LL_FSE_LOG+ML_FSE_LOG+OFF_FSE_LOG) {
            bit_flush_bits(&block_stream)
        }
        bit_add_bits(&block_stream,u64(sequences[n].lit_length),ll_bits)
        bit_add_bits(&block_stream,u64(sequences[n].ml_base),ml_bits)
        if of_bits+ml_bits+ll_bits>56 {bit_flush_bits(&block_stream)}
        if long_offsets {
            extra_bits:=of_bits-min(of_bits,STREAM_ACCUMULATOR_MIN_64-1)
            if extra_bits!=0 {
                bit_add_bits(&block_stream,u64(sequences[n].off_base),extra_bits)
                bit_flush_bits(&block_stream)
            }
            bit_add_bits(&block_stream,u64(sequences[n].off_base>>extra_bits),of_bits-extra_bits)
        } else {
            bit_add_bits(&block_stream,u64(sequences[n].off_base),of_bits)
        }
        bit_flush_bits(&block_stream)
    }

    fse_flush_cstate(&block_stream,&state_match_length)
    fse_flush_cstate(&block_stream,&state_offset_bits)
    fse_flush_cstate(&block_stream,&state_lit_length)

    stream_size:=bit_close_cstream(&block_stream)
    if stream_size==0 {return 0,.Dst_Size_Too_Small}
    return stream_size,.None
}
