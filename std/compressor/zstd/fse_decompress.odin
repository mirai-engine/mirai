package zstd

// The cells of an FSE table are u32: a header, then the decoding table.

FSE_DTABLE_HEADER_U32 :: 1

Fse_DTable_Header :: struct {table_log,fast_mode:u16}
Fse_Decode_T :: struct {new_state:u16,symbol,nb_bits:u8}

Fse_DState :: struct {
    state:uint,
    table:[^]Fse_Decode_T,
}

fse_dtable_size_u32 :: #force_inline proc "contextless" (max_table_log:u32) -> int {return 1+(1<<max_table_log)}
fse_build_dtable_wksp_size :: #force_inline proc "contextless" (max_table_log,max_symbol_value:u32) -> int {return size_of(i16)*int(max_symbol_value+1)+(1<<max_table_log)+8}
fse_decompress_wksp_size_u32 :: #force_inline proc "contextless" (max_table_log,max_symbol_value:u32) -> int {
    return fse_dtable_size_u32(max_table_log)+1+(fse_build_dtable_wksp_size(max_table_log,max_symbol_value)+size_of(u32)-1)/size_of(u32)+(FSE_MAX_SYMBOL_VALUE+1)/2+1
}

fse_table_step :: #force_inline proc "contextless" (table_size:u32) -> u32 {return (table_size>>1)+(table_size>>3)+3}

@(private="file")
fse_build_dtable_internal :: proc "contextless" (dt:[^]u32,normalized_counter:[^]i16,max_symbol_value,table_log:u32,workspace:[^]u8,wksp_size:int) -> Error #no_bounds_check {
    table_decode:=([^]Fse_Decode_T)(&dt[1])
    symbol_next:=([^]u16)(workspace)
    spread:=padd(workspace,int(max_symbol_value+1)*size_of(u16))

    max_sv1:=max_symbol_value+1
    table_size:=u32(1)<<table_log
    high_threshold:=table_size-1

    if fse_build_dtable_wksp_size(table_log,max_symbol_value)>wksp_size {return .Max_Symbol_Value_Too_Large}
    if max_symbol_value>FSE_MAX_SYMBOL_VALUE {return .Max_Symbol_Value_Too_Large}
    if table_log>FSE_MAX_TABLELOG {return .Table_Log_Too_Large}

    {
        header:=Fse_DTable_Header{table_log=u16(table_log),fast_mode=1}
        large_limit:=i16(1)<<(table_log-1)
        for s in 0..<max_sv1 {
            if normalized_counter[s]==-1 {
                table_decode[high_threshold].symbol=u8(s)
                high_threshold-=1
                symbol_next[s]=1
            } else {
                if normalized_counter[s]>=large_limit {header.fast_mode=0}
                symbol_next[s]=u16(normalized_counter[s])
            }
        }
        dt[0]=transmute(u32)header
    }

    if high_threshold==table_size-1 {
        table_mask:=int(table_size-1)
        step:=int(fse_table_step(table_size))
        {
            add:=u64(0x0101010101010101)
            pos:=0
            sv:=u64(0)
            for s in 0..<max_sv1 {
                n:=int(normalized_counter[s])
                write64(padd(spread,pos),sv)
                for i:=8;i<n;i+=8 {
                    write64(padd(spread,pos+i),sv)
                }
                pos+=n
                sv+=add
            }
        }
        {
            position:=0
            for s:=0;s<int(table_size);s+=2 {
                for u in 0..<2 {
                    u_position:=(position+u*step)&table_mask
                    table_decode[u_position].symbol=spread[s+u]
                }
                position=(position+2*step)&table_mask
            }
        }
    } else {
        table_mask:=table_size-1
        step:=fse_table_step(table_size)
        position:=u32(0)
        for s in 0..<max_sv1 {
            for i:=0;i<int(normalized_counter[s]);i+=1 {
                table_decode[position].symbol=u8(s)
                position=(position+step)&table_mask
                for position>high_threshold {position=(position+step)&table_mask}
            }
        }
        if position!=0 {return .Generic}
    }

    for u in 0..<table_size {
        symbol:=table_decode[u].symbol
        next_state:=u32(symbol_next[symbol])
        symbol_next[symbol]+=1
        table_decode[u].nb_bits=u8(table_log-highbit32(next_state))
        table_decode[u].new_state=u16((next_state<<table_decode[u].nb_bits)-table_size)
    }
    return .None
}

@(private="file")
fse_init_dstate :: #force_inline proc "contextless" (d_state:^Fse_DState,bit_d:^Bit_DStream,dt:[^]u32) {
    d_state.state=uint(bit_read_bits(bit_d,u32((transmute(Fse_DTable_Header)dt[0]).table_log)))
    bit_reload_dstream(bit_d)
    d_state.table=([^]Fse_Decode_T)(&dt[1])
}

@(private="file")
fse_decode_symbol :: #force_inline proc "contextless" (d_state:^Fse_DState,bit_d:^Bit_DStream) -> u8 {
    d_info:=d_state.table[d_state.state]
    low_bits:=bit_read_bits(bit_d,u32(d_info.nb_bits))
    d_state.state=uint(d_info.new_state)+uint(low_bits)
    return d_info.symbol
}

// No symbol may have a probability above 50%.
@(private="file")
fse_decode_symbol_fast :: #force_inline proc "contextless" (d_state:^Fse_DState,bit_d:^Bit_DStream) -> u8 {
    d_info:=d_state.table[d_state.state]
    low_bits:=bit_read_bits_fast(bit_d,u32(d_info.nb_bits))
    d_state.state=uint(d_info.new_state)+uint(low_bits)
    return d_info.symbol
}

@(private="file")
fse_get_symbol :: #force_inline proc "contextless" (d_state:^Fse_DState,bit_d:^Bit_DStream,fast:bool) -> u8 {
    return fast ? fse_decode_symbol_fast(d_state,bit_d) : fse_decode_symbol(d_state,bit_d)
}

@(private="file")
fse_decompress_using_dtable_generic :: #force_inline proc "contextless" (dst:[^]u8,max_dst_size:int,c_src:[^]u8,c_src_size:int,dt:[^]u32,fast:bool) -> (size:int,err:Error) #no_bounds_check {
    ostart:=dst
    op:=ostart
    omax:=padd(op,max_dst_size)
    olimit:=padd(omax,-3)

    bit_d:Bit_DStream
    state1,state2:Fse_DState

    if e:=bit_init_dstream(&bit_d,c_src,c_src_size);e!=.None {return 0,e}

    fse_init_dstate(&state1,&bit_d,dt)
    fse_init_dstate(&state2,&bit_d,dt)

    if bit_reload_dstream(&bit_d)==.Overflow {return 0,.Corruption_Detected}

    for bit_reload_dstream(&bit_d)==.Unfinished && uintptr(op)<uintptr(olimit) {
        op[0]=fse_get_symbol(&state1,&bit_d,fast)
        op[1]=fse_get_symbol(&state2,&bit_d,fast)
        op[2]=fse_get_symbol(&state1,&bit_d,fast)
        op[3]=fse_get_symbol(&state2,&bit_d,fast)
        op=padd(op,4)
    }

    for {
        if uintptr(op)>uintptr(padd(omax,-2)) {return 0,.Dst_Size_Too_Small}
        op[0]=fse_get_symbol(&state1,&bit_d,fast)
        op=padd(op,1)
        if bit_reload_dstream(&bit_d)==.Overflow {
            op[0]=fse_get_symbol(&state2,&bit_d,fast)
            op=padd(op,1)
            break
        }

        if uintptr(op)>uintptr(padd(omax,-2)) {return 0,.Dst_Size_Too_Small}
        op[0]=fse_get_symbol(&state2,&bit_d,fast)
        op=padd(op,1)
        if bit_reload_dstream(&bit_d)==.Overflow {
            op[0]=fse_get_symbol(&state1,&bit_d,fast)
            op=padd(op,1)
            break
        }
    }

    return pdiff(op,ostart),.None
}

FSE_DECOMPRESS_NCOUNT_U32 :: (FSE_MAX_SYMBOL_VALUE+1)/2

fse_decompress_wksp :: proc "contextless" (dst:[^]u8,dst_capacity:int,c_src:[^]u8,c_src_size_in:int,max_log:u32,workspace:[^]u32,wksp_size_in:int) -> (size:int,err:Error) #no_bounds_check {
    istart:=c_src
    ip:=istart
    c_src_size:=c_src_size_in
    wksp_size:=wksp_size_in
    table_log:u32
    max_symbol_value:u32=FSE_MAX_SYMBOL_VALUE
    ncount:=([^]i16)(workspace)
    dtable:=workspace[FSE_DECOMPRESS_NCOUNT_U32:]

    if wksp_size<FSE_DECOMPRESS_NCOUNT_U32*size_of(u32) {return 0,.Generic}

    {
        n_count_length:=fse_read_ncount(ncount,&max_symbol_value,&table_log,istart,c_src_size) or_return
        if table_log>max_log {return 0,.Table_Log_Too_Large}
        ip=padd(ip,n_count_length)
        c_src_size-=n_count_length
    }

    if fse_decompress_wksp_size_u32(table_log,max_symbol_value)*size_of(u32)>wksp_size {return 0,.Table_Log_Too_Large}
    rest:=FSE_DECOMPRESS_NCOUNT_U32*size_of(u32)+fse_dtable_size_u32(table_log)*size_of(u32)
    wksp_rest:=padd(([^]u8)(workspace),rest)
    wksp_size-=rest

    if e:=fse_build_dtable_internal(dtable,ncount,max_symbol_value,table_log,wksp_rest,wksp_size);e!=.None {return 0,e}

    fast_mode:=(transmute(Fse_DTable_Header)dtable[0]).fast_mode
    if fast_mode!=0 {return fse_decompress_using_dtable_generic(dst,dst_capacity,ip,c_src_size,dtable,true)}
    return fse_decompress_using_dtable_generic(dst,dst_capacity,ip,c_src_size,dtable,false)
}
