package zstd

FSE_NCOUNTBOUND :: 512
FSE_DEFAULT_TABLELOG :: 11

fse_block_bound :: #force_inline proc "contextless" (size:int) -> int {return size+size>>7+4+size_of(u64)}

fse_build_ctable_workspace_size_u32 :: #force_inline proc "contextless" (max_symbol_value,table_log:u32) -> int {
    return int((u64(max_symbol_value+2)+u64(1)<<table_log)/2)+size_of(u64)/size_of(u32)
}
fse_build_ctable_workspace_size :: #force_inline proc "contextless" (max_symbol_value,table_log:u32) -> int {
    return size_of(u32)*fse_build_ctable_workspace_size_u32(max_symbol_value,table_log)
}

@(private="file")
fse_table_step :: #force_inline proc "contextless" (table_size:u32) -> u32 {return table_size>>1+table_size>>3+3}

Fse_Symbol_Compression_Transform :: struct {
    delta_find_state:i32,
    delta_nb_bits:u32,
}

Fse_CState :: struct {
    value:i64,
    state_table:[^]u16,
    symbol_tt:[^]Fse_Symbol_Compression_Transform,
    state_log:u32,
}

fse_init_cstate :: #force_inline proc "contextless" (state_ptr:^Fse_CState,ct:[^]u32) {
    table_log:=u32(read16(([^]u8)(ct)))
    state_ptr.value=i64(1)<<table_log
    state_ptr.state_table=([^]u16)(ct)[2:]
    state_ptr.symbol_tt=([^]Fse_Symbol_Compression_Transform)(ct[1+(table_log!=0 ? u32(1)<<(table_log-1) : 1):])
    state_ptr.state_log=table_log
}

// The first symbol to include takes the smallest possible state, which saves its cost.
fse_init_cstate2 :: #force_inline proc "contextless" (state_ptr:^Fse_CState,ct:[^]u32,symbol:u32) {
    fse_init_cstate(state_ptr,ct)
    symbol_tt:=state_ptr.symbol_tt[symbol]
    nb_bits_out:=(symbol_tt.delta_nb_bits+(1<<15))>>16
    state_ptr.value=i64((nb_bits_out<<16)-symbol_tt.delta_nb_bits)
    state_ptr.value=i64(state_ptr.state_table[(state_ptr.value>>nb_bits_out)+i64(symbol_tt.delta_find_state)])
}

fse_encode_symbol :: #force_inline proc "contextless" (bit_c:^Bit_CStream,state_ptr:^Fse_CState,symbol:u32) {
    symbol_tt:=state_ptr.symbol_tt[symbol]
    nb_bits_out:=u32((state_ptr.value+i64(symbol_tt.delta_nb_bits))>>16)
    bit_add_bits(bit_c,u64(state_ptr.value),nb_bits_out)
    state_ptr.value=i64(state_ptr.state_table[(state_ptr.value>>nb_bits_out)+i64(symbol_tt.delta_find_state)])
}

fse_flush_cstate :: #force_inline proc "contextless" (bit_c:^Bit_CStream,state_ptr:^Fse_CState) {
    bit_add_bits(bit_c,u64(state_ptr.value),state_ptr.state_log)
    bit_flush_bits(bit_c)
}

// Rounded up; a symbol of frequency 0 costs table_log+1.
fse_get_max_nb_bits :: #force_inline proc "contextless" (symbol_tt_ptr:rawptr,symbol_value:u32) -> u32 {
    symbol_tt:=([^]Fse_Symbol_Compression_Transform)(symbol_tt_ptr)
    return (symbol_tt[symbol_value].delta_nb_bits+((1<<16)-1))>>16
}

// In fixed point with accuracy_log fractional bits; a symbol of frequency 0 costs table_log+1.
fse_bit_cost :: #force_inline proc "contextless" (symbol_tt_ptr:rawptr,table_log,symbol_value,accuracy_log:u32) -> u32 {
    symbol_tt:=([^]Fse_Symbol_Compression_Transform)(symbol_tt_ptr)
    min_nb_bits:=symbol_tt[symbol_value].delta_nb_bits>>16
    threshold:=(min_nb_bits+1)<<16
    table_size:=u32(1)<<table_log
    delta_from_threshold:=threshold-(symbol_tt[symbol_value].delta_nb_bits+table_size)
    normalized_delta_from_threshold:=(delta_from_threshold<<accuracy_log)>>table_log
    bit_multiplier:=u32(1)<<accuracy_log
    return (min_nb_bits+1)*bit_multiplier-normalized_delta_from_threshold
}

fse_build_ctable_wksp :: proc "contextless" (ct:[^]u32,normalized_counter:[^]i16,max_symbol_value,table_log:u32,workspace:[^]u8,wksp_size:int) -> (size:int,err:Error) {
    table_size:=u32(1)<<table_log
    table_mask:=table_size-1
    header:=([^]u16)(ct)
    table_u16:=header[2:]
    symbol_tt:=([^]Fse_Symbol_Compression_Transform)(ct[1+(table_log!=0 ? table_size>>1 : 1):])
    step:=fse_table_step(table_size)
    max_sv1:=max_symbol_value+1

    cumul:=([^]u16)(workspace)
    table_symbol:=([^]u8)(cumul[max_sv1+1:])

    high_threshold:=table_size-1

    if fse_build_ctable_workspace_size(max_symbol_value,table_log)>wksp_size {return 0,.Table_Log_Too_Large}
    header[0]=u16(table_log)
    header[1]=u16(max_symbol_value)

    cumul[0]=0
    for u:=u32(1);u<=max_sv1;u+=1 {
        if normalized_counter[u-1]==-1 {
            cumul[u]=cumul[u-1]+1
            table_symbol[high_threshold]=u8(u-1)
            high_threshold-=1
        } else {
            cumul[u]=cumul[u-1]+u16(normalized_counter[u-1])
        }
    }
    cumul[max_sv1]=u16(table_size+1)

    if high_threshold==table_size-1 {
        spread:=table_symbol[table_size:]
        add:=u64(0x0101010101010101)
        pos:=0
        sv:=u64(0)
        for s:=u32(0);s<max_sv1;s+=1 {
            n:=int(normalized_counter[s])
            write64(spread[pos:],sv)
            for i:=8;i<n;i+=8 {write64(spread[pos+i:],sv)}
            pos+=n
            sv+=add
        }
        position:=uint(0)
        unroll:=uint(2)
        for s:=uint(0);s<uint(table_size);s+=unroll {
            for u:=uint(0);u<unroll;u+=1 {
                u_position:=(position+(u*uint(step)))&uint(table_mask)
                table_symbol[u_position]=spread[s+u]
            }
            position=(position+(unroll*uint(step)))&uint(table_mask)
        }
    } else {
        position:=u32(0)
        for symbol:=u32(0);symbol<max_sv1;symbol+=1 {
            freq:=int(normalized_counter[symbol])
            for nb_occurrences:=0;nb_occurrences<freq;nb_occurrences+=1 {
                table_symbol[position]=u8(symbol)
                position=(position+step)&table_mask
                for position>high_threshold {position=(position+step)&table_mask}
            }
        }
    }

    for u:=u32(0);u<table_size;u+=1 {
        s:=table_symbol[u]
        table_u16[cumul[s]]=u16(table_size+u)
        cumul[s]+=1
    }

    total:=u32(0)
    for s:=u32(0);s<=max_symbol_value;s+=1 {
        switch normalized_counter[s] {
        case 0:
            symbol_tt[s].delta_nb_bits=((table_log+1)<<16)-(u32(1)<<table_log)
        case -1,1:
            symbol_tt[s].delta_nb_bits=(table_log<<16)-(u32(1)<<table_log)
            symbol_tt[s].delta_find_state=i32(total-1)
            total+=1
        case:
            max_bits_out:=table_log-highbit32(u32(normalized_counter[s])-1)
            min_state_plus:=u32(normalized_counter[s])<<max_bits_out
            symbol_tt[s].delta_nb_bits=(max_bits_out<<16)-min_state_plus
            symbol_tt[s].delta_find_state=i32(total-u32(normalized_counter[s]))
            total+=u32(normalized_counter[s])
        }
    }
    return 0,.None
}

fse_ncount_write_bound :: proc "contextless" (max_symbol_value,table_log:u32) -> int {
    max_header_size:=int(((max_symbol_value+1)*table_log+4+2)/8)+1+2
    return max_symbol_value!=0 ? max_header_size : FSE_NCOUNTBOUND
}

@(private="file")
fse_write_ncount_generic :: proc "contextless" (header:[^]u8,header_buffer_size:int,normalized_counter:[^]i16,max_symbol_value,table_log:u32,write_is_safe:bool) -> (size:int,err:Error) {
    ostart:=header
    out:=ostart
    oend:=padd(ostart,header_buffer_size)
    table_size:=int(1)<<table_log
    bit_stream:=u32(0)
    bit_count:=0
    symbol:=u32(0)
    alphabet_size:=max_symbol_value+1
    previous_is0:=false

    bit_stream+=(table_log-FSE_MIN_TABLELOG)<<u32(bit_count)
    bit_count+=4

    remaining:=table_size+1
    threshold:=table_size
    nb_bits:=int(table_log)+1

    for symbol<alphabet_size && remaining>1 {
        if previous_is0 {
            start:=symbol
            for symbol<alphabet_size && normalized_counter[symbol]==0 {symbol+=1}
            if symbol==alphabet_size {break}
            for symbol>=start+24 {
                start+=24
                bit_stream+=u32(0xFFFF)<<u32(bit_count)
                if !write_is_safe && uintptr(out)>uintptr(padd(oend,-2)) {return 0,.Dst_Size_Too_Small}
                out[0]=u8(bit_stream)
                out[1]=u8(bit_stream>>8)
                out=padd(out,2)
                bit_stream>>=16
            }
            for symbol>=start+3 {
                start+=3
                bit_stream+=u32(3)<<u32(bit_count)
                bit_count+=2
            }
            bit_stream+=(symbol-start)<<u32(bit_count)
            bit_count+=2
            if bit_count>16 {
                if !write_is_safe && uintptr(out)>uintptr(padd(oend,-2)) {return 0,.Dst_Size_Too_Small}
                out[0]=u8(bit_stream)
                out[1]=u8(bit_stream>>8)
                out=padd(out,2)
                bit_stream>>=16
                bit_count-=16
            }
        }
        {
            value:=int(normalized_counter[symbol])
            symbol+=1
            max_value:=(2*threshold-1)-remaining
            remaining-=value<0 ? -value : value
            value+=1
            if value>=threshold {value+=max_value}
            bit_stream+=u32(value)<<u32(bit_count)
            bit_count+=nb_bits
            if value<max_value {bit_count-=1}
            previous_is0=value==1
            if remaining<1 {return 0,.Generic}
            for remaining<threshold {nb_bits-=1;threshold>>=1}
        }
        if bit_count>16 {
            if !write_is_safe && uintptr(out)>uintptr(padd(oend,-2)) {return 0,.Dst_Size_Too_Small}
            out[0]=u8(bit_stream)
            out[1]=u8(bit_stream>>8)
            out=padd(out,2)
            bit_stream>>=16
            bit_count-=16
        }
    }

    if remaining!=1 {return 0,.Generic}

    if !write_is_safe && uintptr(out)>uintptr(padd(oend,-2)) {return 0,.Dst_Size_Too_Small}
    out[0]=u8(bit_stream)
    out[1]=u8(bit_stream>>8)
    out=padd(out,(bit_count+7)/8)
    return pdiff(out,ostart),.None
}

fse_write_ncount :: proc "contextless" (buffer:[^]u8,buffer_size:int,normalized_counter:[^]i16,max_symbol_value,table_log:u32) -> (size:int,err:Error) {
    if table_log>FSE_MAX_TABLELOG {return 0,.Table_Log_Too_Large}
    if table_log<FSE_MIN_TABLELOG {return 0,.Generic}
    if buffer_size<fse_ncount_write_bound(max_symbol_value,table_log) {
        return fse_write_ncount_generic(buffer,buffer_size,normalized_counter,max_symbol_value,table_log,false)
    }
    return fse_write_ncount_generic(buffer,buffer_size,normalized_counter,max_symbol_value,table_log,true)
}

// src_size is above 1.
fse_min_table_log :: proc "contextless" (src_size:int,max_symbol_value:u32) -> u32 {
    min_bits_src:=highbit32(u32(src_size))+1
    min_bits_symbols:=highbit32(max_symbol_value)+2
    return min_bits_src<min_bits_symbols ? min_bits_src : min_bits_symbols
}

fse_optimal_table_log_internal :: proc "contextless" (max_table_log:u32,src_size:int,max_symbol_value,minus:u32) -> u32 {
    max_bits_src:=highbit32(u32(src_size-1))-minus
    table_log:=max_table_log
    min_bits:=fse_min_table_log(src_size,max_symbol_value)
    if table_log==0 {table_log=FSE_DEFAULT_TABLELOG}
    if max_bits_src<table_log {table_log=max_bits_src}
    if min_bits>table_log {table_log=min_bits}
    if table_log<FSE_MIN_TABLELOG {table_log=FSE_MIN_TABLELOG}
    if table_log>FSE_MAX_TABLELOG {table_log=FSE_MAX_TABLELOG}
    return table_log
}

fse_optimal_table_log :: proc "contextless" (max_table_log:u32,src_size:int,max_symbol_value:u32) -> u32 {
    return fse_optimal_table_log_internal(max_table_log,src_size,max_symbol_value,2)
}

@(private="file")
fse_normalize_m2 :: proc "contextless" (norm:[^]i16,table_log:u32,count:[^]u32,total_in:int,max_symbol_value:u32,low_prob_count:i16) -> Error {
    NOT_YET_ASSIGNED :: -2
    total:=u64(total_in)
    distributed:=u32(0)

    low_threshold:=u32(total>>table_log)
    low_one:=u32((total*3)>>(table_log+1))

    for s:=u32(0);s<=max_symbol_value;s+=1 {
        if count[s]==0 {
            norm[s]=0
            continue
        }
        if count[s]<=low_threshold {
            norm[s]=low_prob_count
            distributed+=1
            total-=u64(count[s])
            continue
        }
        if count[s]<=low_one {
            norm[s]=1
            distributed+=1
            total-=u64(count[s])
            continue
        }
        norm[s]=NOT_YET_ASSIGNED
    }
    to_distribute:=(u32(1)<<table_log)-distributed

    if to_distribute==0 {return .None}

    if total/u64(to_distribute)>u64(low_one) {
        low_one=u32((total*3)/u64(to_distribute*2))
        for s:=u32(0);s<=max_symbol_value;s+=1 {
            if norm[s]==NOT_YET_ASSIGNED && count[s]<=low_one {
                norm[s]=1
                distributed+=1
                total-=u64(count[s])
                continue
            }
        }
        to_distribute=(u32(1)<<table_log)-distributed
    }

    if distributed==max_symbol_value+1 {
        max_v,max_c:u32
        for s:=u32(0);s<=max_symbol_value;s+=1 {
            if count[s]>max_c {max_v=s;max_c=count[s]}
        }
        norm[max_v]+=i16(to_distribute)
        return .None
    }

    if total==0 {
        for s:=u32(0);to_distribute>0;s=(s+1)%(max_symbol_value+1) {
            if norm[s]>0 {to_distribute-=1;norm[s]+=1}
        }
        return .None
    }

    {
        v_step_log:=u64(62-table_log)
        mid:=(u64(1)<<(v_step_log-1))-1
        r_step:=((u64(1)<<v_step_log)*u64(to_distribute)+mid)/u64(u32(total))
        tmp_total:=mid
        for s:=u32(0);s<=max_symbol_value;s+=1 {
            if norm[s]==NOT_YET_ASSIGNED {
                end:=tmp_total+u64(count[s])*r_step
                s_start:=u32(tmp_total>>v_step_log)
                s_end:=u32(end>>v_step_log)
                weight:=s_end-s_start
                if weight<1 {return .Generic}
                norm[s]=i16(weight)
                tmp_total=end
            }
        }
    }
    return .None
}

@(rodata,private="file") FSE_Rest_To_Beat:=[8]u32{0,473195,504333,520860,550000,700000,750000,830000}

// Returns the table log, 0 if there is a single symbol.
fse_normalize_count :: proc "contextless" (normalized_counter:[^]i16,table_log_in:u32,count:[^]u32,total_in:int,max_symbol_value:u32,use_low_prob_count:bool) -> (size:int,err:Error) #no_bounds_check {
    table_log:=table_log_in
    total:=u64(total_in)
    if table_log==0 {table_log=FSE_DEFAULT_TABLELOG}
    if table_log<FSE_MIN_TABLELOG {return 0,.Generic}
    if table_log>FSE_MAX_TABLELOG {return 0,.Table_Log_Too_Large}
    if table_log<fse_min_table_log(total_in,max_symbol_value) {return 0,.Generic}

    low_prob_count:=i16(use_low_prob_count ? -1 : 1)
    scale:=u64(62-table_log)
    step:=(u64(1)<<62)/u64(u32(total))
    v_step:=u64(1)<<(scale-20)
    still_to_distribute:=int(1)<<table_log
    largest:=u32(0)
    largest_p:=i16(0)
    low_threshold:=u32(total>>table_log)

    for s:=u32(0);s<=max_symbol_value;s+=1 {
        if u64(count[s])==total {return 0,.None}
        if count[s]==0 {normalized_counter[s]=0;continue}
        if count[s]<=low_threshold {
            normalized_counter[s]=low_prob_count
            still_to_distribute-=1
        } else {
            scaled:=u64(count[s])*step
            proba:=i16(scaled>>scale)
            if proba<8 {
                rest_to_beat:=v_step*u64(FSE_Rest_To_Beat[proba])
                if scaled-u64(proba)<<scale>rest_to_beat {proba+=1}
            }
            if proba>largest_p {largest_p=proba;largest=s}
            normalized_counter[s]=proba
            still_to_distribute-=int(proba)
        }
    }
    if -still_to_distribute>=int(normalized_counter[largest]>>1) {
        m2_err:=fse_normalize_m2(normalized_counter,table_log,count,total_in,max_symbol_value,low_prob_count)
        if m2_err!=.None {return 0,m2_err}
    } else {
        normalized_counter[largest]+=i16(still_to_distribute)
    }
    return int(table_log),.None
}

fse_build_ctable_rle :: proc "contextless" (ct:[^]u32,symbol_value:u8) -> (size:int,err:Error) {
    header:=([^]u16)(ct)
    table_u16:=header[2:]
    symbol_tt:=([^]Fse_Symbol_Compression_Transform)(ct[2:])

    header[0]=0
    header[1]=u16(symbol_value)

    table_u16[0]=0
    table_u16[1]=0

    symbol_tt[symbol_value].delta_nb_bits=0
    symbol_tt[symbol_value].delta_find_state=0
    return 0,.None
}

@(private="file")
fse_prev_byte :: #force_inline proc "contextless" (ip:^[^]u8) -> u32 {
    ip^=padd(ip^,-1)
    return u32(ip^[0])
}

@(private="file")
fse_flush_bits :: #force_inline proc "contextless" (bit_c:^Bit_CStream,fast:bool) {
    if fast {bit_flush_bits_fast(bit_c)} else {bit_flush_bits(bit_c)}
}

@(private="file")
fse_compress_using_ctable_generic :: #force_inline proc "contextless" (dst:[^]u8,dst_size:int,src:[^]u8,src_size:int,ct:[^]u32,fast:bool) -> int {
    istart:=src
    iend:=padd(istart,src_size)
    ip:=iend
    remaining:=src_size

    bit_c:Bit_CStream
    c_state1,c_state2:Fse_CState

    if src_size<=2 {return 0}
    if _,init_err:=bit_init_cstream(&bit_c,dst,dst_size);init_err!=.None {return 0}

    if src_size&1!=0 {
        fse_init_cstate2(&c_state1,ct,fse_prev_byte(&ip))
        fse_init_cstate2(&c_state2,ct,fse_prev_byte(&ip))
        fse_encode_symbol(&bit_c,&c_state1,fse_prev_byte(&ip))
        fse_flush_bits(&bit_c,fast)
    } else {
        fse_init_cstate2(&c_state2,ct,fse_prev_byte(&ip))
        fse_init_cstate2(&c_state1,ct,fse_prev_byte(&ip))
    }

    remaining-=2
    if remaining&2!=0 {
        fse_encode_symbol(&bit_c,&c_state2,fse_prev_byte(&ip))
        fse_encode_symbol(&bit_c,&c_state1,fse_prev_byte(&ip))
        fse_flush_bits(&bit_c,fast)
    }

    for uintptr(ip)>uintptr(istart) {
        fse_encode_symbol(&bit_c,&c_state2,fse_prev_byte(&ip))
        fse_encode_symbol(&bit_c,&c_state1,fse_prev_byte(&ip))
        fse_encode_symbol(&bit_c,&c_state2,fse_prev_byte(&ip))
        fse_encode_symbol(&bit_c,&c_state1,fse_prev_byte(&ip))
        fse_flush_bits(&bit_c,fast)
    }

    fse_flush_cstate(&bit_c,&c_state2)
    fse_flush_cstate(&bit_c,&c_state1)
    return bit_close_cstream(&bit_c)
}

fse_compress_using_ctable :: proc "contextless" (dst:[^]u8,dst_size:int,src:[^]u8,src_size:int,ct:[^]u32) -> (size:int,err:Error) {
    if dst_size>=fse_block_bound(src_size) {
        return fse_compress_using_ctable_generic(dst,dst_size,src,src_size,ct,true),.None
    }
    return fse_compress_using_ctable_generic(dst,dst_size,src,src_size,ct,false),.None
}
